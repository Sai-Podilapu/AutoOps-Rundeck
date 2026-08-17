# AutoOps — Frontend only (no backend needed)

This build runs **completely on its own**. The backend is unlinked and the app
uses a built-in offline mock, so you can see and click through everything
without running any server.

## Run it (2 steps)

```powershell
npm install
npm run dev
```

Then open the URL it prints (usually **http://localhost:5173**).

## Log in

Use any email + any password. For example:

- Client / owner view: `owner@autoops.io`  /  `anything`
- Provider view: `provider@autoops.io`  /  `anything`
- OTP code (if asked): any 6 digits, e.g. `123456`

> In offline mode the login always succeeds. Use an email that contains the
> word "provider" to see the provider console; any other email opens the
> normal client app.

## What works vs. what's empty

- The full marketing site (home, hero with your robot, pricing, docs,
  footer, etc.) works normally.
- The signed-in app shell loads and navigates without errors. Data lists
  (jobs, executions, nodes, etc.) show empty states because there is no
  backend yet — that's expected for now.

## Later: turn the backend back on

When your backend is running, disable the mock by creating a file named
`.env` in this folder with:

```
VITE_MOCK=0
```

Then restart `npm run dev`. The app will talk to the real API again (it
proxies `/api` to `http://localhost:4000`).
