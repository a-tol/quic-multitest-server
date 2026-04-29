FROM alpine:3.19

RUN apk add --no-cache curl jq bash

COPY run_tests.sh /run_tests.sh
RUN chmod +x /run_tests.sh

CMD ["/run_tests.sh"]
