"""
name: nehorai.menashe
tester : gal.elhiani
whether project
"""
from datetime import datetime,timedelta
from flask import Flask, render_template, request, redirect, url_for
import requests
import pycountry
import os
import socket
from world_capitals import world_capitals
from dotenv import load_dotenv

"""api for get the country name"""
API_CITY = "https://countries.dev/cities?q="

"""API for translate from any lenguge to english"""
API_TRANSLATE = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&q="

"""dict for the world capitals data"""
country_dict = {country.alpha_2: country.name for country in pycountry.countries}


"""creating the app of flask with the folder"""
app = Flask(__name__)

"""decorators for the path in the url"""
@app.route("/")
def hello():
    """main page"""
    return render_template("./index.html")

@app.route("/version")
def version():
    return {"version": os.environ.get("APP_VERSION", "unknown"),
            "host": socket.gethostname()}


"""using methods post http method for sending the data of the user to the webserver"""
@app.route("/search", methods=["POST"])
def search():
    """routing for search  and to the loction url"""
    """strip the loction that enterd in the form """
    user_input = request.form.get("location","").strip()

    """if the user enterd input to the form then we redirect to the location"""
    if user_input:
        """redirect the user to new url of the function location with the user input data """
        return redirect(url_for("location", location=user_input))
    return redirect(url_for("hello"))

"""finel route with the location wether showing its dynamic url so you can enter to the same page and get the same result of the serch"""
@app.route("/<location>")
def location(location):
    """page for search location with resolts """
    loc = get_loction(location)
    data = city_comined(loc)
    """creating a list with the loction city country and the data of the wheter"""
    results = list(zip(loc, data))
    days = get_7_days()

    """render the tamplets of the search with the tables """
    return render_template("./search.html",results=results,days=days)

def get_loction(data:str)->list:
    """a function taking a name of city or cuntry and passing a list with country and city with all the countries with the same name"""

    data = translate(data)
    """taking the data and making the first letter """
    data = data.lower()
    data = data[0:1].upper() + data[1:]

    """undestanding if thear is at the start or at the end country name"""
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
    """creating a list from data if its a cuntrie"""
    if data in world_capitals.keys():
        return [[data,world_capitals[data]]]

    if " " in data:
        data = data.replace(" ","%20")

    """creating the requst with the apicity and the data url """
    response = requests.get(API_CITY + data)

    if response.status_code == 200:
        data = response.json()

        """duplicate country id fighter"""
        filtered_data = {city['countryCode']: city for city in reversed(data)}
        list_city_country = []

        """creating a list of all the countries with the same name of city """
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
    """get the loctions data in to a list of dicts of all the info about the wether """

    """get the loction in to format of url ready"""
    if " " in location:
        location = location.replace(" ","%20")
    """get the info with api key and the weather api"""
    try:
        load_dotenv()
        API_KEY = os.getenv("API_KEY")
        response = requests.get(f'https://weather.visualcrossing.com/VisualCrossingWebServices/rest/services/timeline/{location}/next7days?unitGroup=uk&key={API_KEY}&contentType=json')
        data = response.json()
    except:
        return []
    weekly_metrics = []
    """ get every day and get its data on temp and Humidity in in night and day"""
    for day in data.get("days", []):
        sunrise_epoch = day["sunriseEpoch"]
        sunset_epoch = day["sunsetEpoch"]
        day_temp_sum = 0
        day_humidity_sum = 0
        day_hours_count = 0
        night_temp_sum = 0
        night_humidity_sum = 0
        night_hours_count = 0

        """get the sum of the temp in each time line"""
        for hour in day.get("hours", []):
            if sunrise_epoch <= hour["datetimeEpoch"] < sunset_epoch:
                is_daytime = True
            else:
                is_daytime = False

            if is_daytime:
                day_temp_sum += hour["temp"]
                day_humidity_sum += hour["humidity"]
                day_hours_count += 1
            else:
                night_temp_sum += hour["temp"]
                night_humidity_sum += hour["humidity"]
                night_hours_count += 1

        """getting the avg for each of the days """
        if day_hours_count > 0:
            day_temp_avg = round(day_temp_sum / day_hours_count, 2)
            day_humidity_avg = round(day_humidity_sum / day_hours_count, 2)
        else:
            day_temp_avg = 0
            day_humidity_avg = 0
        if night_hours_count > 0:
            night_temp_avg = round(night_temp_sum / night_hours_count, 2)
            night_humidity_avg = round(night_humidity_sum / night_hours_count, 2)
        else:
            night_temp_avg = 0
            night_humidity_avg = 0
        """insert it to the list weekly_metrics"""
        weekly_metrics.append({
            "day_temp": day_temp_avg,
            "night_temp": night_temp_avg,
            "day_humidity": day_humidity_avg,
            "night_humidity": night_humidity_avg
        })
    return weekly_metrics

def city_comined(loctions:list) -> list:
    """getting all the data of the cities in to list that have more list inside that has dictionery of the data of every city"""
    finle_weather = []
    for arr in loctions:
        if not arr or len(arr) < 2:
            continue
        finle_weather.append(get_loction_data(arr[0] +" "+ arr[1]))
    return finle_weather

def get_7_days():
    """getting the 7 days after today from the day we are at"""
    days = [ 'Sunday' ,'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
    today = datetime.now()
    new_days = []
    for i in range(8):
        """getting the index of the the day we are in in index"""
        index = (today + timedelta(days=i)).weekday()
        new_days.append(days[index])
    return new_days

def translate(data: str) -> str:
    """translate the language to english"""
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
