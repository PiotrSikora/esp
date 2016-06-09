# Copyright (C) Endpoints Server Proxy Authors
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#
################################################################################
#
use strict;
use warnings;

################################################################################

BEGIN { use FindBin; chdir($FindBin::Bin); }

use ApiManager;   # Must be first (sets up import path to the Nginx test module)
use Test::Nginx;  # Imports Nginx's test module
use Test::More;   # And the test framework
use HttpServer;
use ServiceControl;
use JSON::PP;

################################################################################

# Port assignments
my $NginxPort = 8080;
my $ServiceControlPort = 8081;
my $GrpcServerPort = 8082;
my $DummyNonGrpcTrafficPort = 8083;

my $t = Test::Nginx->new()->has(qw/http proxy/)->plan(21);

$t->write_file('service.json',
  ApiManager::get_transcoding_test_service_config(
    'endpoints-transcoding-test.cloudendpointsapis.com',
    "http://127.0.0.1:${ServiceControlPort}"));

ApiManager::write_file_expand($t, 'nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
events {
  worker_connections 32;
}
http {
  %%TEST_GLOBALS_HTTP%%
  server_tokens off;
  server {
    listen 127.0.0.1:${NginxPort};
    server_name localhost;
    location / {
      endpoints {
        api service.json;
        %%TEST_CONFIG%%
        on;
      }
      grpc_pass {
        proxy_pass http://127.0.0.1:${DummyNonGrpcTrafficPort}/;
      }
      grpc_backend_address_override 127.0.0.1:${GrpcServerPort};
    }
  }
}
EOF

my $report_done = 'report_done';

$t->run_daemon(\&service_control, $t, $ServiceControlPort, 'servicecontrol.log', $report_done);
ApiManager::run_transcoding_test_server($t, 'server.log', "127.0.0.1:${GrpcServerPort}");

is($t->waitforsocket("127.0.0.1:${ServiceControlPort}"), 1, "Service control socket ready.");
is($t->waitforsocket("127.0.0.1:${GrpcServerPort}"), 1, "GRPC test server socket ready.");
$t->run();
is($t->waitforsocket("127.0.0.1:${NginxPort}"), 1, "Nginx socket ready.");

################################################################################

my $initial_shelves_response = http_get('/shelves?key=api-key');

my $bulk_shelves_response = http(<<EOF);
POST /bulk/shelves?key=api-key HTTP/1.0
Host: 127.0.0.1:${NginxPort}
Content-Type: application/json
Content-Length: 158

[
{ "theme" : "Classics" },
{ "theme" : "Satire" },
{ "theme" : "Russian" },
{ "theme" : "Children" },
{ "theme" : "Documentary" },
{ "theme" : "Mystery" },
]
EOF

my $final_shelves_response = http_get('/shelves?key=api-key');

# Wait for the service control report
is($t->waitforfile("$t->{_testdir}/${report_done}"), 1, 'Report body file ready.');
$t->stop_daemons();

# Check the requests that the backend has received
my $initial_shelves_request_expected = {};
my $bulk_shelves_reqeust1_expected = { 'shelf' => {'theme' => 'Classics'}};
my $bulk_shelves_reqeust2_expected = { 'shelf' => {'theme' => 'Satire'}};
my $bulk_shelves_reqeust3_expected = { 'shelf' => {'theme' => 'Russian'}};
my $bulk_shelves_reqeust4_expected = { 'shelf' => {'theme' => 'Children'}};
my $bulk_shelves_reqeust5_expected = { 'shelf' => {'theme' => 'Documentary'}};
my $bulk_shelves_reqeust6_expected = { 'shelf' => {'theme' => 'Mystery'}};
my $final_shelves_request_expected = {};

my $server_output = $t->read_file('server.log');
my @server_requests = split /\r\n\r\n/, $server_output;

ok(ApiManager::compare_json($server_requests[0], $initial_shelves_request_expected));
ok(ApiManager::compare_json($server_requests[1], $bulk_shelves_reqeust1_expected));
ok(ApiManager::compare_json($server_requests[2], $bulk_shelves_reqeust2_expected));
ok(ApiManager::compare_json($server_requests[3], $bulk_shelves_reqeust3_expected));
ok(ApiManager::compare_json($server_requests[4], $bulk_shelves_reqeust4_expected));
ok(ApiManager::compare_json($server_requests[5], $bulk_shelves_reqeust5_expected));
ok(ApiManager::compare_json($server_requests[6], $bulk_shelves_reqeust6_expected));
ok(ApiManager::compare_json($server_requests[7], $final_shelves_request_expected));

# Check responses
my $initial_shelves_response_expected = {
  'shelves' => [
    {'id' => '1', 'theme' => 'Fiction'},
    {'id' => '2', 'theme' => 'Fantasy'},
  ]
};
my $bulk_shelves_response_expected = [
   {'id' => '3', 'theme' => 'Classics'},
   {'id' => '4', 'theme' => 'Satire'},
   {'id' => '5', 'theme' => 'Russian'},
   {'id' => '6', 'theme' => 'Children'},
   {'id' => '7', 'theme' => 'Documentary'},
   {'id' => '8', 'theme' => 'Mystery'},
];

my $final_shelves_response_expected = {
  'shelves' => [
    {'id' => '1', 'theme' => 'Fiction'},
    {'id' => '2', 'theme' => 'Fantasy'},
    {'id' => '3', 'theme' => 'Classics'},
    {'id' => '4', 'theme' => 'Satire'},
    {'id' => '5', 'theme' => 'Russian'},
    {'id' => '6', 'theme' => 'Children'},
    {'id' => '7', 'theme' => 'Documentary'},
    {'id' => '8', 'theme' => 'Mystery'},
  ]
};

ApiManager::compare_http_response_json_body($initial_shelves_response, $initial_shelves_response_expected);
ApiManager::compare_http_response_json_body($bulk_shelves_response, $bulk_shelves_response_expected);
ApiManager::compare_http_response_json_body($final_shelves_response, $final_shelves_response_expected);

# Check service control calls
# We expect 3 service control calls:
#   - 1 check call for both calls to ListShelves (as we are using the same API key the
#     second time check response is in the cache)
#   - 1 check call for the call to BulkCreateShelf,
#   - 1 aggregated report call containing 2 operations - ListShelves and BulkCreateShelf
my @servicecontrol_requests = ApiManager::read_http_stream($t, 'servicecontrol.log');
is(scalar @servicecontrol_requests, 3, 'Service control was called 3 times');

my $report_request = pop @servicecontrol_requests;
like($report_request->{uri}, qr/:report$/, 'Report has correct uri');
my $report_json = decode_json(ServiceControl::convert_proto($report_request->{body}, "report_request", "json"));
my @operations = @{$report_json->{operations}};
is(scalar @operations, 2, 'There are 2 operations');

################################################################################

sub service_control {
  my ($t, $port, $file, $done) = @_;

  my $server = HttpServer->new($port, $t->testdir() . '/' . $file)
    or die "Can't create test server socket: $!\n";

  local $SIG{PIPE} = 'IGNORE';

  $server->on_sub('POST', '/v1/services/endpoints-transcoding-test.cloudendpointsapis.com:check', sub {
    my ($headers, $body, $client) = @_;
    print $client <<EOF;
HTTP/1.1 200 OK
Content-Type: application/json
Connection: close

EOF
  });

  $server->on_sub('POST', '/v1/services/endpoints-transcoding-test.cloudendpointsapis.com:report', sub {
    my ($headers, $body, $client) = @_;
    print $client <<EOF;
HTTP/1.1 200 OK
Content-Type: application/json
Connection: close

EOF
    $t->write_file($done, ":report done");
  });

  $server->run();
}

################################################################################
