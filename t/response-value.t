use v5.40;
use Test2::V1 -ipP;
use Test2::Thunderhorse;
use HTTP::Request::Common;

use Future::AsyncAwait;

################################################################################
# This tests returning PAGI response values from Thunderhorse handlers
################################################################################

package ValueApp {
	use Mooish::Base -standard;
	use Future::AsyncAwait;
	use PAGI::Response qw(response);

	extends 'Thunderhorse::App';

	sub build ($self)
	{
		my %routes = (
			'/returned_json' => sub ($self, $ctx) {
				return response('JSON', {returned => 1}, status => 201);
			},
			'/returned_stream' => sub ($self, $ctx) {
				return response(
					'Stream',
					async sub ($writer) {
						await $writer->write("one\n");
						await $writer->write("two\n");
					},
					content_type => 'text/plain; charset=utf-8',
				);
			},
			'/value' => sub ($self, $ctx) {
				$ctx->res->value(response('Text', 'from value'));
			},
			'/value_then_body' => sub ($self, $ctx) {
				$ctx->res->value(response('Text', 'from value'));
				$ctx->res->status(500)->html('error page');
			},
			'/value_ignores_setters' => sub ($self, $ctx) {
				$ctx->res->status(500)->header('X-Before' => 'yes');
				$ctx->res->value(response('Text', 'from value'))->status(404);
			},
		);

		$self->router->add($_ => {to => $routes{$_}}) for sort keys %routes;
	}
}

my $app = ValueApp->new;

subtest 'a returned JSON response is sent as it is' => sub {
	http $app, GET '/returned_json';
	http_status_is 201;
	http_header_is 'content-type', 'application/json';
	is http->json, {returned => 1}, 'body ok';
};

subtest 'a returned streaming response is sent' => sub {
	http $app, GET '/returned_stream';
	http_status_is 200;
	http_text_is "one\ntwo\n";
};

subtest 'value sets the whole response' => sub {
	http $app, GET '/value';
	http_status_is 200;
	http_header_is 'content-type', 'text/plain; charset=utf-8';
	http_text_is 'from value';
};

subtest 'value ignores setters before and after it' => sub {
	http $app, GET '/value_ignores_setters';
	http_status_is 200;
	is http->header('x-before'), undef, 'earlier header not sent';
	http_text_is 'from value';
};

subtest 'a body method after value replaces it' => sub {
	http $app, GET '/value_then_body';
	http_status_is 500;
	http_header_is 'content-type', 'text/html; charset=utf-8';
	http_text_is 'error page';
};

done_testing;
