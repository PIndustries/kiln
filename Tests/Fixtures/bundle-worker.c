/* Native bundle acceptance fixture: assets, relative shared-library loading and
 * persistent data, without a language runtime or external services. */
#include <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

extern int bundle_value(void);
int main(int argc, char **argv) {
    const char *root = getenv("KILN_RELEASE_DIR"), *port = getenv("KILN_PORT");
    if (!root || !port) return 2;
    char path[4096], asset[128] = {0};
    snprintf(path, sizeof(path), "%s/assets/message.txt", root);
    FILE *file = fopen(path, "r");
    if (!file || !fgets(asset, sizeof(asset), file)) return 3;
    fclose(file); asset[strcspn(asset, "\r\n")] = 0;
    int starts = 0;
    file = fopen("starts", "r");
    if (file) { if (fscanf(file, "%d", &starts) != 1) return 4; fclose(file); }
    file = fopen("starts", "w");
    if (!file) return 5;
    fprintf(file, "%d", ++starts); fclose(file);
    int server = socket(AF_INET, SOCK_STREAM, 0), yes = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons((unsigned short)atoi(port));
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 16)) return 6;
    for (;;) {
        int client = accept(server, NULL, NULL);
        if (client < 0) continue;
        char request[1024], body[512], response[1024];
        if (read(client, request, sizeof(request)) <= 0) { close(client); continue; }
        int length = snprintf(body, sizeof(body), "{\"asset\":\"%s\",\"library\":%d,\"starts\":%d}", asset, bundle_value(), starts);
        int unavailable = argc > 1 && !strcmp(argv[1], "fail");
        int size = snprintf(response, sizeof(response), "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", unavailable ? "503 Unavailable" : "200 OK", length, body);
        (void)write(client, response, (size_t)size); close(client);
    }
}
