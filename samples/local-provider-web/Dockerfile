FROM python:3.13-alpine

RUN addgroup -g 10001 sample \
    && adduser -D -H -u 10001 -G sample sample

WORKDIR /app
COPY --chown=10001:10001 app.py ./app.py

USER 10001:10001
EXPOSE 8000
CMD ["python", "app.py"]
