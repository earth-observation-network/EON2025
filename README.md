# EON Summer School 2025

## Editing the main website

To edit the main website, you can edit the `index.qmd` file in the root directory of the repository.

## Adding new content

To add new content to the website, you can create a new folder with a `.qmd` file inside it. 
The folder name will be used as the URL path for the new content.

To add this new content to the website, you need to add a link to it in the `_quarto.yml` file.

## Before updating the website

Please do not push new/updated `.qmd` files that run any code directly, but rather render the website locally (on your own computer), and then push the new files to GitHub.
To render the website locally, you need to use a terminal (not an R console):

```
quarto render
```

This will add new files (pre-rendered versions of the `.qmd` documents) to the `_freeze` folder.
You can then push these files to GitHub.
This push will automatically trigger a new GitHub Actions build, which will update the website.
