# nginx in front of gunicorn, serving /static/ from the NetBox image's collectstatic
# output. `app` is the netbox service's image (compose additional_contexts), so the
# static files always match the running NetBox version.
FROM nginx:1.30.6-alpine
COPY --from=app /opt/netbox/netbox/static /usr/share/netbox/static
COPY nginx.conf /etc/nginx/conf.d/default.conf
