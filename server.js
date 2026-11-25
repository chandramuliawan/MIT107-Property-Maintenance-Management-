const http = require("node:http");
const fs = require("node:fs");
const path = require("node:path");

const root = __dirname;
const frontend = path.join(root, "frontend");
const routes = new Map([
    ["/", "login.html"],
    ["/login", "login.html"],
    ["/tenant/dashboard", "tenant-dashboard.html"],
    ["/agent/dashboard", "agent-dashboard.html"],
    ["/tenant/issues/new", "new-issue.html"]
]);

const contentTypes = new Map([
    [".css", "text/css; charset=utf-8"],
    [".html", "text/html; charset=utf-8"],
    [".js", "text/javascript; charset=utf-8"],
    [".json", "application/json; charset=utf-8"],
    [".png", "image/png"],
    [".svg", "image/svg+xml"]
]);

function sendFile(response, filePath) {
    fs.readFile(filePath, (error, content) => {
        if (error) {
            response.writeHead(error.code === "ENOENT" ? 404 : 500, {
                "Content-Type": "text/plain; charset=utf-8"
            });
            response.end(error.code === "ENOENT" ? "Not found" : "Unable to read requested file");
            return;
        }

        response.writeHead(200, {
            "Content-Type": contentTypes.get(path.extname(filePath)) || "application/octet-stream",
            "X-Content-Type-Options": "nosniff"
        });
        response.end(content);
    });
}

const server = http.createServer((request, response) => {
    if (request.method !== "GET" && request.method !== "HEAD") {
        response.writeHead(405, { Allow: "GET, HEAD" });
        response.end("Method not allowed");
        return;
    }

    let pathname;
    try {
        pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    } catch {
        response.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
        response.end("Invalid URL");
        return;
    }
    pathname = pathname.replace(/\/+$/, "") || "/";

    const page = routes.get(pathname);
    if (page) {
        sendFile(response, path.join(frontend, page));
        return;
    }
    if (/^\/issues\/[^/]+$/.test(pathname)) {
        sendFile(response, path.join(frontend, "issue-details.html"));
        return;
    }

    if (!pathname.startsWith("/frontend/")) {
        response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
        response.end("Not found");
        return;
    }

    const filePath = path.resolve(frontend, pathname.slice("/frontend/".length));
    const relativePath = path.relative(frontend, filePath);
    if (relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
        response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
        response.end("Not found");
        return;
    }

    fs.stat(filePath, (error, stats) => {
        if (error || !stats.isFile()) {
            response.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
            response.end("Not found");
            return;
        }
        sendFile(response, filePath);
    });
});

const port = Number(process.env.PORT) || 3000;
server.listen(port, () => {
    console.log(`Property Maintenance frontend running at http://localhost:${port}`);
});
