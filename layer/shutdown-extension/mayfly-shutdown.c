#define _GNU_SOURCE
/*
 * mayfly-shutdown: a minimal external Lambda extension whose only job is to
 * exist. When an external extension is registered, Lambda sends SIGTERM to the
 * runtime before tearing the execution environment down (and allows up to 2 s),
 * which lets Mayfly.Shutdown run its hooks and flush logs. Without one, the
 * environment is frozen and discarded with no notice.
 *
 * Protocol (Extensions API, 2020-01-01):
 *   POST /extension/register   {"events":["SHUTDOWN"]}  -> Lambda-Extension-Identifier
 *   GET  /extension/event/next (blocks)                 -> {"eventType":"SHUTDOWN",...}
 * On SHUTDOWN we exit 0. No dependencies beyond libc; built statically so it
 * runs on provided.al2023 for both architectures.
 */
#include <arpa/inet.h>
#include <stdint.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define NAME "mayfly-shutdown"

static int connect_api(void) {
  /* AWS_LAMBDA_RUNTIME_API is always "127.0.0.1:<port>" inside the sandbox.
     getaddrinfo() is avoided on purpose: in a static glibc binary it needs NSS
     shared objects and crashes. */
  const char *api = getenv("AWS_LAMBDA_RUNTIME_API");
  if (!api) { fprintf(stderr, NAME ": AWS_LAMBDA_RUNTIME_API not set\n"); exit(1); }
  char host[64]; const char *colon = strrchr(api, ':');
  if (!colon) { fprintf(stderr, NAME ": bad runtime api %s\n", api); exit(1); }
  size_t hl = (size_t)(colon - api); if (hl >= sizeof host) hl = sizeof host - 1;
  memcpy(host, api, hl); host[hl] = 0;
  struct sockaddr_in addr; memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET; addr.sin_port = htons((uint16_t)atoi(colon + 1));
  if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    if (strcmp(host, "localhost") == 0) addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    else { fprintf(stderr, NAME ": runtime api host must be an IPv4 address, got %s\n", host); exit(1); }
  }
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0 || connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) { fprintf(stderr, NAME ": connect failed\n"); exit(1); }
  return fd;
}

/* Sends a request, reads the full response into buf, returns bytes read. */
static ssize_t http(const char *req, char *buf, size_t cap) {
  int fd = connect_api();
  size_t len = strlen(req), off = 0;
  while (off < len) { ssize_t n = write(fd, req + off, len - off); if (n <= 0) { close(fd); return -1; } off += (size_t)n; }
  size_t got = 0;
  for (;;) {
    ssize_t n = read(fd, buf + got, cap - 1 - got);
    if (n <= 0) break;
    got += (size_t)n;
    if (got >= cap - 1) break;
    /* Stop once Content-Length bytes of body have arrived. */
    char *hdr_end = strstr(buf, "\r\n\r\n");
    if (hdr_end) {
      buf[got] = 0;
      char *cl = strcasestr(buf, "content-length:");
      if (cl) { long want = atol(cl + 15); if ((long)(got - (size_t)(hdr_end + 4 - buf)) >= want) break; }
    }
  }
  buf[got] = 0; close(fd); return (ssize_t)got;
}

int main(void) {
  char buf[8192]; char req[1024]; char id[256] = {0};
  const char *api = getenv("AWS_LAMBDA_RUNTIME_API"); if (!api) api = "";
  const char *body = "{\"events\":[\"SHUTDOWN\"]}";
  snprintf(req, sizeof req,
    "POST /2020-01-01/extension/register HTTP/1.1\r\nHost: %s\r\nLambda-Extension-Name: " NAME
    "\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", api, strlen(body), body);
  if (http(req, buf, sizeof buf) <= 0 || strncmp(buf, "HTTP/1.1 200", 12) != 0) { fprintf(stderr, NAME ": register failed: %.200s\n", buf); return 1; }
  char *h = strcasestr(buf, "lambda-extension-identifier:");
  if (!h) { fprintf(stderr, NAME ": no identifier\n"); return 1; }
  h += 28; while (*h == ' ') h++;
  size_t i = 0; while (h[i] && h[i] != '\r' && h[i] != '\n' && i < sizeof id - 1) { id[i] = h[i]; i++; } id[i] = 0;

  for (;;) {
    snprintf(req, sizeof req,
      "GET /2020-01-01/extension/event/next HTTP/1.1\r\nHost: %s\r\nLambda-Extension-Identifier: %s\r\nConnection: close\r\n\r\n", api, id);
    if (http(req, buf, sizeof buf) <= 0) { fprintf(stderr, NAME ": event/next failed\n"); return 1; }
    if (strstr(buf, "\"SHUTDOWN\"")) { printf(NAME ": shutdown event received, exiting\n"); fflush(stdout); return 0; }
  }
}
