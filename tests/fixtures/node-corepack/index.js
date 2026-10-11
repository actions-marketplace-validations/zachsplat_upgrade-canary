const http = require("node:http");

http
  .createServer((req, res) => {
    res.end(req.url === "/health" ? "ok\n" : "hello\n");
  })
  .listen(3000, () => console.log(`ready on 3000, node ${process.version}`));
