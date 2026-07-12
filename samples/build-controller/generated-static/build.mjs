import { mkdir, writeFile } from "node:fs/promises";

await mkdir("dist", { recursive: true });
await writeFile(
  "dist/index.html",
  "<!doctype html><html><body><main><h1>Generated static build passed</h1></main></body></html>\n",
  "utf8",
);
