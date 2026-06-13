from dataclasses import dataclass, field


@dataclass
class Session:
    """App-level session data keyed by thread_id (not LangGraph checkpoint state)."""

    messages: list[dict[str, str]] = field(default_factory=list)
    mentioned_cities: list[str] = field(default_factory=list)


class SessionStore:
    def __init__(self) -> None:
        self._sessions: dict[str, Session] = {}

    def get_or_create(self, thread_id: str) -> Session:
        if thread_id not in self._sessions:
            self._sessions[thread_id] = Session()
        return self._sessions[thread_id]

    def get(self, thread_id: str) -> Session | None:
        return self._sessions.get(thread_id)

    def clear(self, thread_id: str) -> None:
        self._sessions.pop(thread_id, None)


def build_llm_user_message(session: Session, user_message: str) -> str:
    context = _build_session_context(session)
    if context:
        return f"{context}\n\n{user_message}"
    return user_message


def _build_session_context(session: Session) -> str | None:
    if not session.mentioned_cities:
        return None

    cities = ", ".join(session.mentioned_cities[-3:])
    return f"Session context: User previously asked about weather in {cities}."


def update_session_from_turn(
    session: Session,
    user_message: str,
    reply: str,
    agent_messages: list,
) -> None:
    session.messages.append({"role": "user", "content": user_message})
    session.messages.append({"role": "assistant", "content": reply})

    for msg in agent_messages:
        tool_calls = getattr(msg, "tool_calls", None)
        if not tool_calls:
            continue

        for tool_call in tool_calls:
            name = tool_call.get("name") if isinstance(tool_call, dict) else tool_call["name"]
            args = tool_call.get("args") if isinstance(tool_call, dict) else tool_call["args"]
            if name != "get_weather":
                continue

            city = args.get("city", "").strip()
            if city and city not in session.mentioned_cities:
                session.mentioned_cities.append(city)
