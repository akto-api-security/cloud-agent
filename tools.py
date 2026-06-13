import httpx
from langchain_core.tools import tool


@tool
def get_weather(city: str) -> str:
    """Get the current weather for a city. Example: 'London', 'New York', 'Tokyo'."""
    city = city.strip()
    if not city:
        return "Please provide a city name."

    try:
        response = httpx.get(
            f"https://wttr.in/{city}",
            params={"format": "j1"},
            timeout=10.0,
            headers={"User-Agent": "cloud-agent/1.0"},
        )
        response.raise_for_status()
        data = response.json()
    except (httpx.HTTPError, KeyError, IndexError, ValueError) as exc:
        return f"Could not fetch weather for {city}: {exc}"

    current = data["current_condition"][0]
    area = data["nearest_area"][0]
    location = area["areaName"][0]["value"]
    country = area["country"][0]["value"]
    temp_c = current["temp_C"]
    feels_like_c = current["FeelsLikeC"]
    humidity = current["humidity"]
    description = current["weatherDesc"][0]["value"]

    return (
        f"Weather in {location}, {country}:\n"
        f"- Condition: {description}\n"
        f"- Temperature: {temp_c}°C (feels like {feels_like_c}°C)\n"
        f"- Humidity: {humidity}%"
    )
