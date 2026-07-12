const http = require("node:http");

const port = Number(process.env.PORT || 8000);
http.createServer((_request, response) => {
  response.setHeader("content-type", "application/json");
  response.end(JSON.stringify({ status: "ok", plan: "node_web" }));
}).listen(port, "0.0.0.0");
