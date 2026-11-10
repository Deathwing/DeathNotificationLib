# Changelog

## 1.0.1

- When more than one copy is installed, the newest installed copy is used. Copies from before this release cannot be taken over and stay in use until they are updated.
- Loads on World of Warcraft: Forever with its own heatmaps, built only from Forever clients. Each game version loads only its own data files. Until enough Forever deaths are collected the Forever file is empty, so the heatmaps use your own log there.
- `DeathNotificationLibData.xml` is gone. Addons that load the data from their own copy of the library copy the file lines from `DeathNotificationLibData.toc` into their TOC unchanged, including the `[AllowLoadGameType]` and `[ExcludeLoadGameType]` conditions.

## 1.0.0

### Initial release
