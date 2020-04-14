# Installation
This page describes the installation steps

## Plugins

Following plugins are activated

* Topic Preview https://github.com/angusmcleod/discourse-topic-previews

## Theme
Theme related customizations

* A customized theme for our web-app https://github.com/fatihaksel/creative-kidz-theme
* Custom Header Component --> https://github.com/discourse/discourse-custom-header-links
    ```
    Most Liked, Posts with the most amount of likes, /latest/?order=op_likes, vdo, self, keep
    Code::Buffalo, This is a Hackathon project , https://www.43north.org/code-buffalo/, vdo, blank, remove
    ```


Rebuild the app

```
cd /var/discourse
./launcher rebuild app
```
