# Offline workflow tool dependencies

The gallery scripts run with Node.js 20+ or Python 3. Users do not need npm or any packages installed. The generated vendor.cjs files and emoji.json ship with each self-contained workflow folder and retain their third-party licenses.

To rebuild bundled libraries/data after a deliberate dependency update:

```sh
cd scripts/workflow-tools
npm ci
node build.cjs
```

Commit the updated bundles, notices and package-lock.json together. This build script is development-only and is never included in installed workflows. Tools execute no network requests.

Run the Node tool checks from the repository root with `node --test scripts/tests/test_workflow_tools.cjs`. Run Python checks with `python3 -m unittest discover -s scripts/tests -p test_workflow_tools.py`. Swift gallery integration tests validate installation and launcher outputs.

Inspired by the tool selection at [IT Tools](https://it-tools.tech/). Implementations use independent code and permissively licensed dependencies; no IT Tools source is copied. Java cron follows [Quartz's documented syntax](https://www.quartz-scheduler.org/documentation/quartz-2.3.0/tutorials/crontrigger.html).
