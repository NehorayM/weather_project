"""
name: nehorai.menashe
tester : gal.elhiani
weather project
"""
import os
import socket
from datetime import datetime, timedelta
import pycountry
import requests
from dotenv import load_dotenv
from flask import Flask, redirect, render_template, request, url_for
from prometheus_flask_exporter import Counter, PrometheusMetrics
from world_capitals import world_capitals

"""api for get the country name"""
API_CITY = "https://countries.dev/cities?q="

"""API for translate from any lenguge to english"""
API_TRANSLATE = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&q="

"""dict for the world capitals data"""
country_dict = {country.alpha_2: country.name for country in pycountry.countries}

"""creating the app of flask with the folder"""
app = Flask(__name__)

# --- Prometheus Metrics Setup ---
metrics = PrometheusMetrics(app)

# static app info metric (פאנל Running version בגרפנה)
metrics.info(
    "weather_app_info",
    "Application info",
    version=os.environ.get("APP_VERSION", "1.0.1"),
)

# counter for city lookups (פאנלים של Top cities ו-City lookups per minute)
city_lookups_counter = Counter(
    "weather_city_lookups_total",
    "Number of weather lookups per city",
    ["city"],
)


@app.route("/")
def hello():
    """main page"""
    return render_template("./index.html")


@app.route("/version")
def version():
    return {
        "version": os.environ.get("APP_VERSION", "unknown"),
        "host": socket.gethostname(),
    }


@app.route("/search", methods=["POST"])
def search():
    """routing for search and to the loction url"""
    user_input = request.form.get("location", "").strip()
    if user_input:
        return redirect(url_for("location", location=user_input))
    return redirect(url_for("hello"))


@app.route("/<location>")
def location(location):
    """page for search location with results"""
    # קידום מונה החיפושים עבור העיר המבוקשת ב-Prometheus
    city_lookups_counter.labels(city=location).inc()

    loc = get_loction(location)
    data = city_comined(loc)
    results = list(zip(loc, data))
    days = get_7_days()
    return render_template("./search.html", results=results, days=days)


def get_loction(data: str) -> list:
    data = translate(data)
    data = data.lower()
    data = data[0:1].upper() + data[1:]

    country = None
    for name in country_dict.values():
        if data.lower().endswith(" " + name.lower()):
            country = name
            data = data[:-len(name) - 1]
            break
        if data.lower().startswith(name.lower() + " "):
            country = name
            data = data[len(name) + 1:]
            break

    if data in world_capitals.keys():
        return [[data, world_capitals[data]]]

    if " " in data:
        data = data.replace(" ", "%20")

    response = requests.get(API_CITY + data)
    if response.status_code == 200:
        raw_data = response.json()
        filtered_data = {city["countryCode"]: city for city in reversed(raw_data)}
        list_city_country = []
        for item in filtered_data.values():
            code = item["countryCode"]
            country_name = country_dict.get(code)
            if country and country_name != country:
                continue
            city_name = item["name"]
            list_city_country.append([country_name, city_name])
        return list_city_country
    return []


def get_loction_data(location: str) -> list:
    if " " in location:
        location = location.replace(" ", "%20")
    try:
        load_dotenv()
        API_KEY = os.getenv("API_KEY")
        response = requests.get(
            f"https://weather.visualcrossing.com/VisualCrossingWebServices/rest/services/timeline/{location}/next7days?unitGroup=uk&key={API_KEY}&contentType=json"
        )
        data = response.json()
    except Exception:
        return []

    weekly_metrics = []
    for day in data.get("days", []):
        sunrise_epoch = day["sunriseEpoch"]
        sunset_epoch = day["sunsetEpoch"]
        day_temp_sum = 0
        day_humidity_sum = 0
        day_hours_count = 0
        night_temp_sum = 0
        night_humidity_sum = 0
        night_hours_count = 0

        for hour in day.get("hours", []):
            is_daytime = sunrise_epoch <= hour["datetimeEpoch"] < sunset_epoch
            if is_daytime:
                day_temp_sum += hour["temp"]
                day_humidity_sum += hour["humidity"]
                day_hours_count += 1
            else:
                night_temp_sum += hour["temp"]
                night_humidity_sum += hour["humidity"]
                night_hours_count += 1

        day_temp_avg = round(day_temp_sum / day_hours_count, 2) if day_hours_count > 0 else 0
        day_humidity_avg = round(day_humidity_sum / day_hours_count, 2) if day_hours_count > 0 else 0
        night_temp_avg = round(night_temp_sum / night_hours_count, 2) if night_hours_count > 0 else 0
        night_humidity_avg = round(night_humidity_sum / night_hours_count, 2) if night_hours_count > 0 else 0

        weekly_metrics.append({
            "day_temp": day_temp_avg,
            "night_temp": night_temp_avg,
            "day_humidity": day_humidity_avg,
            "night_humidity": night_humidity_avg,
        })
    return weekly_metrics


def city_comined(loctions: list) -> list:
    finle_weather = []
    for arr in loctions:
        if not arr or len(arr) < 2:
            continue
        finle_weather.append(get_loction_data(arr[0] + " " + arr[1]))
    return finle_weather


def get_7_days():
    days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    today = datetime.now()
    return [days[(today + timedelta(days=i)).weekday()] for i in range(8)]


def translate(data: str) -> str:
    if not data[0].isascii():
        if " " in data:
            data = data.replace(" ", "%20")
        response = requests.get(API_TRANSLATE + data)
        if response.status_code == 200:
            data = response.json()
        return data[0][0][0]
    return data


if __name__ == "__main__":
    app.run()
