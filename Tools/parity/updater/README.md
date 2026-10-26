# Update-site parity

`UpdaterOracle.java` checks Mancora's update-site support (`Sources/MancoraPlugins`) against Fiji's own updater, [imagej-updater](https://github.com/imagej/imagej-updater). It builds a small installation and two update sites:

- installed, updateable (under an older versioned name), locally modified, new, declined and obsolete files;
- files for one platform only, a dependency that has to come along, and a file one site shadows on another;
- two local versions of one file, a site that records an older updater's checksum, a launcher, and local-only files.

It runs the real `FilesCollection`, `Checksummer`, `Conflicts` and `Installer` over them, serving the sites from a local HTTP server. Then it records what the updater decided:

- every file's status and action, and the conflicts reported
- the folder after installing, and the `db.xml.gz` the updater wrote
- the same after disabling one of the sites
- the checksums of jars that take every path through the updater's `.properties` and manifest filters

`Tests/MancoraPluginsTests` replays the same steps with `PluginManager` and must reach the same results, down to the bytes of `db.xml.gz`.

To regenerate the fixtures (needs git, a JDK and network access):

    Tools/parity/updater/run.sh

The script compiles imagej-updater from a pinned commit together with scijava-common, runs the oracle in UTC, and replaces `Tests/MancoraPluginsTests/Fixtures/updater`.
