# Preconfigured QUIC HTTP/3 Test Server Docker Images

## Requirements
1) Docker
2) Open Ports, if running locally. See the below steps.

## Building the H2O HTTP/3 Server Containers
1) Have docker installed
2) in the ./h2o directory, run 
```
sudo docker compose build
``` 
to create the server images.


3) run 
```
sudo docker compose up
```
to create the server containers.

	- To change what ports are hosting what on your local machine, change the "xxxx" field in the "- xxxx:yyyy" (HOST PORT:CONTAINER PORT) mappings in the "ports" tag of the docker-compose.yml file.
	- The default host_port:container_port mappings for the HTTP/3 endpoints are:
		h2o-server (Reno): 8444 (8443 TCP)
		h2o-pico-server: 8446 (8445 TCP)
		h2o-cubic-server: 8448 (8447 TCP)
	the servers will host files on these ports via QUIC/HTTP3 (NO TCP FALLBACK).
	an alternative TCP host is available with every container and is hosted with the same hostname, with the QUIC port number minus one.
	
these servers should be accessible with URL similar to: 

https://localhost:8444/file.txt.

(replace file.txt with any of the payload names, port number to match which server).
	
4) to kill these server containers, run 
```
sudo docker compose down 
```in the ./h2o directory.

## Building the OpenLiteSpeed Server Containers

5) in EACH ols-docker-env folder, run "sudo docker compose up" to run its container.
The docker process should download the base OpenLiteSpeed image and run it. The QUIC algorithm setting change is already applied; each folder is named after the congestion control algorithm used in the container.

To change what ports are hosting the servers on your local machine, similarly change the "xxxx" field in the "- xxxx:yyyy " HOST:PORT in the "ports" tag of the docker-compose.yml file.
- This would have to be done on the individual folder level. 
- Ports hosts BOTH HTTP/2 and HTTP/3.
The default host:port mappings are:
litespeed-default: 27015
litespeed-bbr: 27016
litespeed-cubic: 27017

these servers should be accessible as:
	https://localhost:27015/file.txt
	(replace file.txt with any of the payload names).

6) run 
```
sudo docker compose down
```
 in a container's folder to kill it.

7) to access the admin server for configuration settings, access the server with the special "1776x" port noted in the docker-compose.yml file.
By default these are
litespeed-default: 17760
litespeed-bbr: 17761
litespeed-cubic: 17762

the login should be
username: admin
password: superstrongpassword
by default

(don't even try doing it on our the aws endpoint. i changed the password.)


## Using the cURL client with these the HTTP3 Client/Network Experiments

This will require a custom cURL binary with HTTP3 integration, which can be downloaded from https://github.com/stunnel/static-curl.

1) download the cURL binary.
2) Query either the locally hosted endpoint from earlier with
```
	/path/to/curl -k [--http3-only | --http3 ] [endpoint] [--output FILE]
```
	or one of (hopefully still hosted) endpoints, like
```
	/path/to/curl --http3-only -k https://ec2-13-222-23-193.compute-1.amazonaws.com:8444/file.txt
```