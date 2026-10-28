# LFI CTF --- Setup \& Exploit Notes

## Overview

A small web-exploitation CTF demonstrating **Local File Inclusion (LFI)
/ path traversal**. Nginx is the public-facing web server and reverse
proxy; Flask implements the API and admin portal.

**Intended solve:** discover `/api/files` and its `path` parameter →
read `../.env` → recover `ADMIN\_API\_KEY` → submit it at `/api/admin/` →
obtain the flag.

> Run only in an isolated lab. The vulnerable endpoint can read files
> that the Flask process has permission to access.

## Project layout

``` text
lfi/
├── app.py
├── requirements.txt
├── challenge\_fs/
│   ├── .env                 # Fake challenge config/key only
│   └── public/
│       ├── guide.txt
│       ├── readme.txt
│       ├── changelog.txt
│       └── faq.txt
├── templates/
│   ├── index.html
│   └── admin.html
├── static/
    └── styles.css
```

## Requirements

Kali/Linux, Python 3, `venv`, Nginx, and curl. `requirements.txt`
installs Flask and pytest.

## Run Flask locally

From the project root:

``` bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python app.py
```

Flask listens on `127.0.0.1:5000`. Keep this terminal running.


## Vulnerability

In `app.py`, the `/api/files` handler reads the user-controlled `path`
parameter and resolves it relative to `PUBLIC\_DIR`:

``` python
candidate = (PUBLIC\_DIR / filename).resolve()
```

The vulnerable version does **not** verify that the resolved path
remains inside `PUBLIC\_DIR` before reading it. Therefore, `../.env`
resolves from `challenge\_fs/public/` to `challenge\_fs/.env`. Other files
readable by the Flask process may also be accessible, subject to OS
permissions.

The `/api/download` route is separate and rejects traversal. The LFI is
in `/api/files`.

## Solve the challenge

Use the Nginx-facing URL (port 80):

1. Browse `http://127.0.0.1/` and inspect `/api/help`, public
documentation, or requests in browser DevTools/Burp.
2. Read the simulated configuration:

&#x20;   ``` bash
    curl -G 'http://127.0.0.1/api/files' --data-urlencode 'path=../.env'
    ```

3. Copy the `ADMIN\_API\_KEY` value from the response.
4. Open `http://127.0.0.1/api/admin/` and submit the key.
5. A correct key displays the flag on the same page.

To check service detection:

``` bash
sudo nmap -sV -p 80,5000 localhost
```

Port 80 should identify Nginx. Port 5000 may identify Werkzeug when
scanning locally; Flask is bound to loopback and should not be directly
reachable from other machines.

## Tests

From the project root:

``` bash
source .venv/bin/activate
python -m pytest -v
```

Run tests from the project root, not from inside `tests/`, so
`import app` works.

## Defender patch

In `app.py`, inside `view\_file()`, after resolving the candidate and
before reading it, enforce the directory boundary:

``` python
if not candidate.is\_relative\_to(PUBLIC\_DIR):
    return jsonify({"error": "Access denied"}), 403
```

Then verify that public files still work and `path=../.env` is rejected.
Prefer an allowlist of known public filenames, keep secrets outside the
web content directory, and run Flask with minimum OS permissions.

## Safety and deployment

* `.env` must contain only fictional challenge credentials.
* Do not expose this vulnerable version on a host containing real
secrets or sensitive files.
* For public deployment, use a disposable, isolated VM/container or
similarly restricted environment, and keep the backend inaccessible
directly from the network.
* Nginx is the front end; **the LFI vulnerability is implemented in
Flask**, not by an Nginx `alias` misconfiguration.

