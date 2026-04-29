FROM nginx:1.25-alpine

RUN apk add --no-cache openssl

COPY nginx.conf   /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080/tcp

ENTRYPOINT ["/entrypoint.sh"]
