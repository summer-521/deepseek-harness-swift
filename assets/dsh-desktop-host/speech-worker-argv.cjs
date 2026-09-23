const { readFileSync } = require("node:fs");

// The npm worker still parses argv[2]; restore it before its entry runs.
process.argv[2] = readFileSync(0, "utf8");
