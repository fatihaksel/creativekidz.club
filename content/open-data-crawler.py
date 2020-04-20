#!/usr/bin/env python
# coding: utf-8
# Creative Kidz Data Crawler
#
import pandas as pd
import re

# Data set
DATASET_API_ENDPOINT = "https://data.ny.gov/resource/fymg-3wv3.json"
# for more information about the dataset please visit https://data.ny.gov/Human-Services/Child-Care-Regulated-Programs-API/fymg-3wv3
ERIE_COUNTY = "county=Erie"
DATASET_API_ENDPOINT += "?" + ERIE_COUNTY
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

    return cc_desc


if __name__ == '__main__':
    # filter dataset

    # loop through rows
    for index, row in df.iterrows():
        print(index, add_group(row))
