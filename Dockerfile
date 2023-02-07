FROM node:latest

COPY entrypoint.sh /entrypoint.sh

# See https://github.com/actions/runner-images/issues/6775#issuecomment-1410627843
RUN git config --system --add safe.directory *

ENTRYPOINT ["/entrypoint.sh"]
