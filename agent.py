import logging
import os
import uuid

from dotenv import load_dotenv
from langgraph.prebuilt import create_react_agent

try:
    from langgraph.errors import GraphRecursionError
except ImportError:
    class GraphRecursionError(Exception):
        pass

from bedrock_config import create_bedrock_llm
from session_store import (
    SessionStore,
    build_llm_user_message,
    update_session_from_turn,
)
from tools import get_weather

load_dotenv()

logger = logging.getLogger(__name__)

TOOLS = [get_weather]

SYSTEM_PROMPT = (
    "You are a helpful weather assistant. "
    "Use the get_weather tool when the user asks about current weather in a city. "
    "If the city is ambiguous, ask a brief clarifying question."
)

session_store = SessionStore()


class AgentError(Exception):
    def __init__(self, status_code: int, message: str):
        self.status_code = status_code
        self.message = message
        super().__init__(message)


def create_agent(model_id: str | None = None):
    """Build a compiled LangGraph ReAct agent (langgraph.prebuilt.create_react_agent)."""
    llm = create_bedrock_llm(model_id)
    return create_react_agent(
        llm,
        TOOLS,
        prompt=SYSTEM_PROMPT,
    )


def _normalize_content(content) -> str | None:
    if content is None:
        return None
    if isinstance(content, str):
        text = content.strip()
        return text or None
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
        text = "\n".join(part for part in parts if part).strip()
        return text or None
    text = str(content).strip()
    return text or None


def extract_reply(result: dict) -> str:
    messages = result.get("messages") or []
    for message in reversed(messages):
        if type(message).__name__ in {"HumanMessage", "ToolMessage"}:
            continue

        content = _normalize_content(getattr(message, "content", None))
        if content:
            return content

    raise AgentError(502, "Agent returned no text response")


def invoke_agent(agent, message: str, thread_id: str) -> str:
    session = session_store.get_or_create(thread_id)
    llm_message = build_llm_user_message(session, message)

    try:
        result = agent.invoke({"messages": [("user", llm_message)]})
        reply = extract_reply(result)
        update_session_from_turn(session, message, reply, result["messages"])
        return reply
    except AgentError:
        raise
    except GraphRecursionError as exc:
        logger.warning("Agent recursion limit hit for thread %s", thread_id)
        raise AgentError(
            502,
            "Agent took too many steps. Try a simpler question.",
        ) from exc
    except Exception as exc:
        logger.exception("Agent invoke failed for thread %s", thread_id)
        raise AgentError(
            502,
            "Agent is temporarily unavailable. Please try again.",
        ) from exc


def clear_session(thread_id: str) -> None:
    session_store.clear(thread_id)


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
    )
    agent = create_agent()
    thread_id = str(uuid.uuid4())

    print("Cloud agent (Bedrock boto3 via LangChain). Type 'quit' to exit.")
    print(f"Session: {thread_id}\n")

    while True:
        try:
            user_input = input("You: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nBye.")
            break

        if not user_input:
            continue
        if user_input.lower() in {"quit", "exit", "q"}:
            print("Bye.")
            break

        try:
            reply = invoke_agent(agent, user_input, thread_id)
        except AgentError as exc:
            print(f"\nAgent error: {exc.message}\n")
            continue

        print(f"\nAgent: {reply}\n")


if __name__ == "__main__":
    main()
