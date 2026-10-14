# CI supplies the verified static musl artifact; this image contains no hbbs data.
FROM scratch
ARG SOURCE_REVISION
LABEL org.opencontainers.image.source="https://github.com/michailr1/FuntiDesk" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"
COPY --chmod=0555 funtidesk-account /funtidesk-account
USER 10001:10001
ENTRYPOINT ["/funtidesk-account"]
