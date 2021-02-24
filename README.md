# ftz

A small and simple file transfer utility.

**Features:**
- Upload and download files
- Server can chose to provide only downloads or uploads
- Clients are restricted to the subfolders, no way to break out.
- Native cross platform support (Windows, Linux, MacOS, BSDs)
- Static, small binary (207K on Linux, 128K on Windows, 123K on MacOS)

**Usage:**
```
ftz [verb]
  Quickly transfer files between two systems connected via network.

Verbs:
  ftz help
    Prints this help
  
  ftz host [path] [--get-dir path] [--put-dir path] [--port num] 
    Hosts the given directories for either upload or download.
    path            If given, sets both --get-dir and --put-dir to the same directory.
    --get-dir path  Sets the directory for transfers to a client. No access outside this directory is allowed.
    --put-dir path  Sets the directory for transfers from a client. No access outside this directory is allowed.
    --port    num   Sets the port where ftz will serve the data. Default is 17457
  
  ftz get [--output file] [uri]
    Fetches a file from [uri] into the current directory. The file name will be the file name in the URI.
    uri             The uri to the file that should be downloaded.
    --output file   Saves the resulting file into [file] instead of the basename of the URI.
  
  ftz put [file] [uri]
    Uploads [file] (a local path) to [uri] (a ftz uri)

  ftz version
    Prints the ftz version.

Examples:
  ftz host .
    Open the current directory for both upload and download.
  ftz put debug.log ftz://device.local/debug.log
    Uploads debug.log to the server.
  ftz get ftz://device.local/debug.log
    Downloads debug.log from the server.
```

## Usage / Concept  / Design

FTZ was designed to transfer files between virtual machines and the host system or different machines on the same local network.

It is not designed to be a constantly running server, especially not on the internet and thus has (by design) no authentication, no session resumption or whatsoever. It has an integrity check though to verify if the transfer was successful.

## Building
[![Build](https://github.com/MasterQ32/ftz/actions/workflows/cross-build.yml/badge.svg)](https://github.com/MasterQ32/ftz/actions/workflows/cross-build.yml)

To build `ftz` you need the lastest zig master (>= `0.8.0-dev.1159+d9e46dcee`), then invoke:
```
zig build
```

Then fetch your file from `zig-cache/bin` and use it!

## URI Format

The URI format for FTZ only allows the scheme (`ftz://`), a hostname and the path. An uri that contains a username, password, query or fragment is invalid and will not be accepted.

**Examples:**
```
ftz://random-projects.net/ftz.service
ftz://random-projects.net:124/ftz.service
```

## Protocol

Uses TCP, port 17457

**FETCH:**
```
C: => "GET $(PATH)\r\n"
S: => "$(MD5SUM)"
S: => "$(DATA)" | connection drop
```

**PUT:**
```
C: => "PUT $(PATH)\r\n"
C: => "$(MD5SUM)"
S: => nothing | connection drop
C: => "$(DATA)"
```
