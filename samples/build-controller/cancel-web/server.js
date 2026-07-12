require("node:http").createServer((_request, response) => response.end("ok\n")).listen(8000, "0.0.0.0");
