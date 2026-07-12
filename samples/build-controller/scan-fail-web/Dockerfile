FROM alpine@sha256:ca1c944a4f8486a153024d9965aafbe24f5723c1d5c02f4964c045a16d19dc54
RUN mkdir -p /www && printf '%s\n' 'scan policy fixture' > /www/index.html
EXPOSE 8000
CMD ["httpd", "-f", "-p", "8000", "-h", "/www"]
