FROM alpine:latest

RUN apk add --no-cache curl bash bc

COPY run_tests.sh /run_tests.sh
RUN chmod +x /run_tests.sh

ENTRYPOINT ["/run_tests.sh"]
