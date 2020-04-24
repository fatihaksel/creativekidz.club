# creativekidz.club
We know that it is hard to keep kids busy at home, especially if parents want them engaged in a meaningful activity that helps them develop. With the COVID-19 outbreak and lockdown, almost all of the family members now work at home, kids study at home.

We gather and share creative, fun, easy to do activities for kids. The platform is designed to crowd-source projects, activities for kids to work independently or as a group.

It is a knowledge-base, learning & sharing platform to keep kids entertained during the coronavirus crisis.

![Creative Kidz Logo](./design/ck_logo_yellow_small.png)

**[Our Hackathon Blog ](./VERSION.md)**

We have a survey for parents here --> https://www.surveymonkey.com/r/JQD8N37

## Built With

Project is based on open-source Q&A software [Discourse](https://en.wikipedia.org/wiki/Discourse_(software))

* [Javascript](https://developer.mozilla.org/en-US/docs/Web/JavaScript) - Frontend
* [Ruby](https://www.ruby-lang.org/en/) - Backend Language
* [SQLite](https://sqlite.org/) - Database
* [Discourse Development](https://meta.discourse.org/t/beginners-guide-to-install-discourse-for-development-using-docker/102009) - Discourse Development using docker. [Addon & Theme Building](https://www.broculos.net/2015/09/getting-started-with-discourse.html) - Getting Started with Discourse Development
* We used [The Socrata Open Data API (SODA)](https://dev.socrata.com/) to access the open data platform and created a python script to integrate the data. The crawler script is located at [content/open-data-crawler.py](./content/open-data-crawler.py).
* We have developed a customized theme for our web-app https://github.com/fatihaksel/creative-kidz-theme
* Please check out the [Installation file](./INSTALLATION.md)
* [Docker](https://www.docker.com/) - Project is based on docker, hosted on Digital Ocean Droplets. [Docker CLI](https://docs.docker.com/engine/reference/commandline/cli/) - Docker Command Line Interface docs
* Droplet specific codes are in the [droplet folder](./droplet/)

## Open Data Integration

We have integrated Buffalo Open Data ["Child Care Regulated Programs API"](https://data.ny.gov/Human-Services/Child-Care-Regulated-Programs-API/fymg-3wv3). This data includes the licensed and registered child care programs in New York State.

We have integrated the child care centers that are located in Erie County. There are **499 registered child care centers** in Erie County.

[Browse integrated child care centers](https://creativekidz.club/g)

## The Future Plans

* Continue to improve the prototype infrastructure while developing age-appropriate programs for clients.
* Adding Childcare Centers to help them to create a learning & sharing platform with their kids and parents.
* Adding premium features for teachers, allowing continued engagement beyond school and normal homework.
* We plan to partner with schools and maker labs to enhance STEAM initiatives.
* We will continue to work closely with mentors to lead projects.

For more information please check out [the idea document](./IDEA.md)

## Team Members

* *Axel* - Software Engineer / Full Stack Developer
    * University at Buffalo Child Care Center Board Member
    * [GitHub](https://github.com/fatihaksel)
    * [LinkedIn](https://www.linkedin.com/in/fatih-aksel/)
* *Jeff* - Customer Developer / Front End Developer
    * [GitHub](https://github.com/wayraw)
    * [LinkedIn](https://www.linkedin.com/in/jeffraugh/)
* *Hazel* - UB Assistant Professor / Product Manager
    * [LinkedIn](https://www.linkedin.com/in/hacer-aksel-79062867/)


## Acknowledgments

* Creative Kidz Club is a project built for [Code:Buffalo Hackathon](https://www.43north.org/code-buffalo/)
* [Deniz Kalkan]( https://www.instagram.com/denkalart/) thank you for graphic designs
* We would like to thank our great mentors
