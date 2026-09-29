FROM mysql:8.4

# Install Python 3 and MySQL connector via microdnf
RUN microdnf install -y python3 python3-pip && \
    pip3 install --no-cache-dir mysql-connector-python && \
    microdnf clean all

# Copy schema and seeding logic into MySQL's auto-init directory
COPY schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY seed.py /docker-entrypoint-initdb.d/seed.py
COPY 02_run_seed.sh /docker-entrypoint-initdb.d/02_run_seed.sh

RUN chmod +x /docker-entrypoint-initdb.d/02_run_seed.sh