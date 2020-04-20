#!/usr/bin/env python
# coding: utf-8
# Creative Kidz Data Crawler
#
import pandas as pd
import re
import requests
import json

# Data set
DATASET_API_ENDPOINT = "https://data.ny.gov/resource/fymg-3wv3.json"
# for more information about the dataset please visit https://data.ny.gov/Human-Services/Child-Care-Regulated-Programs-API/fymg-3wv3
ERIE_COUNTY = "county=Erie"
DATASET_API_ENDPOINT += "?" + ERIE_COUNTY

# Creative Kidz API Section
CK_API_KEY = ""
CK_GROUPS_API_ENDPOINT = "https://creativekidz.club/admin/groups"
CK_HEADERS = {
    'Api-Key': CK_API_KEY,
    'Api-Username': 'axelfatih',
    'Content-Type': 'multipart/form-data;'
}

# Child Care program codes
PROGRAM_TYPE_DICT = {
    "FDC": "Family Day Care",
    "GFDC":  "Group Family Day Care",
    "SACC": "School Age Child Care",
    "DCC": "Day Care Center",
    "SDCC": "Small Day Care Center"
}


def urlify(s):

    # Remove all non-word characters (everything except numbers and letters)
    s = re.sub(r"[^\w\s]", '', s)

    # Replace all runs of whitespace with a single dash
    s = re.sub(r"\s+", '-', s)

    return s

# Add child care center as a group


def add_group(row):
    if row is None:
        return ""
    # do some calculations
    id = str(row['facility_id'])
    full_name = row['facility_name'].title()
    group_name = urlify(full_name)
    program_type = PROGRAM_TYPE_DICT.get(row["program_type"], "N/A")

    cc_desc = id + " - " + full_name + " - " + group_name + " - " + program_type
    print(cc_desc)

    payload = {
        "group[name]": id,
        "group[full_name]": full_name,
        "group[bio_raw]": program_type
    }

    r = requests.post(CK_GROUPS_API_ENDPOINT,
                      params=payload, headers=CK_HEADERS)


if __name__ == '__main__':
    # filter dataset
    df = pd.read_json(DATASET_API_ENDPOINT)

    # loop through rows
    for index, row in df.iterrows():
        add_group(row)
