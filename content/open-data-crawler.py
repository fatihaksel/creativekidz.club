#!/usr/bin/env python
# coding: utf-8
# Creative Kidz Open Data Integration Script

import pandas as pd
import re
import requests
import json

# Constant Definitions

# Dataset API Endpoint
# for more information about the dataset
# please visit https://data.ny.gov/Human-Services/Child-Care-Regulated-Programs-API/fymg-3wv3
DATASET_API_ENDPOINT = "https://data.ny.gov/resource/fymg-3wv3.json"
# Dataset is filtered by County
ERIE_COUNTY = "county=Erie"
DATASET_API_ENDPOINT += "?" + ERIE_COUNTY
# Child Care program codes
# You can find the detailed information about the programs inside the dataset website
PROGRAM_TYPE_DICT = {
    "FDC": "Family Day Care",
    "GFDC":  "Group Family Day Care",
    "SACC": "School Age Child Care",
    "DCC": "Day Care Center",
    "SDCC": "Small Day Care Center"
}

# Creative Kidz web-site API Settings
CK_API_KEY = ""
CK_GROUPS_API_ENDPOINT = "https://creativekidz.club/admin/groups"
CK_HEADERS = {
    'Api-Key': CK_API_KEY,
    'Api-Username': 'axelfatih',
    'Content-Type': 'multipart/form-data;'
}


def urlify(s):
    '''
    Convert a script to a user-name friendly field
    '''
    # Remove all non-word characters (everything except numbers and letters)
    s = re.sub(r"[^\w\s]", '', s)

    # Replace all runs of whitespace with a single dash
    s = re.sub(r"\s+", '-', s)

    return s


def add_group(row):
    '''
    Add the given row as a group to the website
    '''
    if row is None:
        return ""
    # get related fields
    id = str(row['facility_id'])
    full_name = row['facility_name'].title()
    group_name = urlify(full_name)
    program_type = PROGRAM_TYPE_DICT.get(row["program_type"], "N/A")

    cc_desc = id + " - " + full_name + " - " + group_name + " - " + program_type
    print(cc_desc)
    # prepare the payload
    payload = {
        "group[name]": id,
        "group[full_name]": full_name,
        "group[bio_raw]": program_type
    }
    try:
        # send the request
        r = requests.post(CK_GROUPS_API_ENDPOINT,
                          params=payload, headers=CK_HEADERS)
    except:
        print("An exception occurred")


if __name__ == '__main__':
    # get dataset as a dataframe
    df = pd.read_json(DATASET_API_ENDPOINT)

    # loop through all rows
    for index, row in df.iterrows():
        add_group(row)
