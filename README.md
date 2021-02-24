# ftz

Easy file transfer utility.

Usage:

```
ftz host [directory] [--upload-dir path] [--port XXXX]

ftz get [src]
  [src] has format ftz://hostname:port/path/to/file

ftz put [file] [dst]
  [file] is a path to a local file
  [dst] is a url ftz://hostname:port/path/to/file
```

## Protocol

Uses TCP, port 17457

**FETCH:**
```
C: => "GET $(PATH)\r\n"
S: => "$(MD5SUM)"
S: => "$(file contents)" | connection drop
```

**PUT:**
```
C: => "PUT $(PATH)\r\n"
C: => "$(MD5SUM)"
S: => nothing | connection drop
C: => "$(file contents)"
```

```
clear && ( echo -ne 'PUT /new/../../new/date.txt\r\n'; date ) | nc 127.0.0.1 17457 -w1 
```