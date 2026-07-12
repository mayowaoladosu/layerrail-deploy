require("node:http").createServer((_request, response) => response.end("recovered\n")).listen(8000, "0.0.0.0");
