<p align="center">
    <a href="https://lowtechguys.com/cling"><img width="128" height="128" src="Cling/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" style="filter: drop-shadow(0px 2px 4px rgba(80, 50, 6, 0.2));"></a>
    <h1 align="center"><code style="text-shadow: 0px 3px 10px rgba(8, 0, 6, 0.35); font-size: 3rem; font-family: ui-monospace, Menlo, monospace; font-weight: 800; background: transparent; color: #4d3e56; padding: 0.2rem 0.2rem; border-radius: 6px">Cling</code></h1>
    <h4 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace;">Instant fuzzy find any file</h4>
    <h6 align="center" style="padding: 0; margin: 0; font-family: ui-monospace, monospace; font-weight: 400;">Act on it in the same instant</h6>
</p>

<p align="center">
    <a href="https://files.lowtechguys.com/releases/Cling.dmg">
        <img width=200 src="https://files.lowtechguys.com/macos-app.svg">
    </a>
</p>

### Installation

- Download the app from the [website](https://lowtechguys.com/cling) and drag it to your `Applications` folder
- *Homebrew will be available once this repository gains [at least 75 stars](https://docs.brew.sh/Acceptable-Casks#rejected-casks)*

![screenshot](https://files.lowtechguys.com/cling-app-screenshot.png)

### Features

- **Find any file instantly**: Cling leverages the power of [fd](https://github.com/sharkdp/fd) and [fzf](https://github.com/junegunn/fzf) to provide lightning-fast fuzzy searching of your entire filesystem.
- **Act on selected files**: Perform any action on files with quick hotkeys - no mouse required. Use Quick Filters to narrow down results and apply predefined actions like Open with…, copy paths, batch rename, or QuickLook.
- **Everything for Mac**: Cling strives to be similar to the popular Everything app from Windows, with macOS native integration and a focus on power users.
- **Index only what you need**: Exclude files from the index to keep your search results clean and focused. Use the `~/.fsignore` file to specify gitignore patterns for excluding files and folders from the index.
- **Search external volumes**: Volumes like USB drives, external hard drives, and network shares are indexed by default and searchable by Cling without any latency.

---

### Comparison with other apps

#### Spotlight, Alfred, Raycast

Cling is similar to these apps in that it provides instant search results, but the key differences are:

- **Fuzzy search**: find files with partial or misspelled queries
- **System files**: search system files, hidden files, dotfiles, and app data that the Spotlight index doesn't include

#### ProFind, HoudahSpot, EasyFind, Tembo, Find Any File

Cling is very much not like these apps.

They are all file search apps that provide advanced search features, allowing you to craft complex queries using metadata and file content to dig deep into your filesystem and find as many files as possible.

Cling is for quickly finding one or more specific files by roughly knowing the name, and then doing something with the file immediately like:

- copying it for sending on chat
- adding to a shelf like Yoink
- opening it in an app like Pixelmator
- uploading it using Dropshare
- executing a script on the file

**Cling is not an app for finding all files that match a complex query.**

---

### Performance considerations

#### Memory usage

To provide instant search results, Cling maintains an in-memory index of your filesystem. This can consume a significant amount of memory, ranging from `300MB` to `2GB` depending on the size of your filesystem and the number of files indexed.

Whenever Cling is in background *(the window is not visible)*, the index will be marked as **swappable to disk**. This allows macOS to move the index to disk and free up RAM when memory pressure is high. Cling will reload the index from disk when you open its window again.

#### CPU usage

The most CPU-intensive operations are:

- **Indexing**: when Cling is indexing your filesystem for the first time, it will consume a significant amount of CPU for about 1 to 5 minutes
- **Re-indexing**: periodically, about once every 3 days, Cling will re-index the filesystem to keep the index up-to-date
- **Fuzzy search**: When you type in the search bar, Cling will perform a fuzzy search on the index to find matching files

Searching will consume a lot of CPU but in short bursts, so every time you stop typing, you'll see high CPU usage for 1-5 seconds then it will drop to 0%.

When Cling is in background, it will pause searching and it will consume very little CPU to index file changes.

#### Battery usage

The impact on battery is proportional to how many searches you do and how many file changes will happen in the background.

Even though a search will look like it's consuming 100% CPU of multiple cores, it's a very fast operation and the battery energy used isn't that high in the long term.

Processing and indexing file changes is very efficient and will not impact battery life significantly.
