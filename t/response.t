use v5.40;
use Test2::V1 -ipP;
use Test2::Thunderhorse;
use HTTP::Request::Common;

################################################################################
# This tests the Thunderhorse::Response builder
################################################################################

package Stringifies {
	use overload '""' => sub { 'stringified object' }, fallback => 1;

	sub new ($class)
	{
		return bless {}, $class;
	}
}

package ResponseApp {
	use Mooish::Base -standard;

	extends 'Thunderhorse::App';

	sub build ($self)
	{
		my %routes = (
			'/text' => sub ($self, $ctx) { $ctx->res->text("caf\x{e9}") },
			'/text_object' => sub ($self, $ctx) { $ctx->res->text(Stringifies->new) },
			'/html' => sub ($self, $ctx) { $ctx->res->html('<p>hi</p>') },
			'/json' => sub ($self, $ctx) { $ctx->res->json({ok => 1}) },
			'/redirect' => sub ($self, $ctx) { $ctx->res->redirect('/target') },
			'/redirect_301' => sub ($self, $ctx) { $ctx->res->redirect('/target', 301) },
			'/redirect_after_status' => sub ($self, $ctx) { $ctx->res->status(201)->redirect('/target') },
			'/status_try' => sub ($self, $ctx) { $ctx->res->status(201)->status_try(200)->text('kept') },
			'/status_default' => sub ($self, $ctx) { $ctx->res->text($ctx->res->status) },
			'/explicit_type' => sub ($self, $ctx) { $ctx->res->content_type('application/xml')->text('<a/>') },
			'/explicit_charset' => sub ($self, $ctx) {
				$ctx->res->content_type('text/csv; charset=latin1')->text('a,b')
			},
			'/json_type' => sub ($self, $ctx) { $ctx->res->content_type('application/vnd.api+json')->json({}) },
			'/header' => sub ($self, $ctx) { $ctx->res->header('X-Example' => 'one')->text('h') },
			'/header_content_type' => sub ($self, $ctx) {
				$ctx->res->header('Content-Type' => 'text/x-custom')->text('h')
			},
			'/no_content' => sub ($self, $ctx) { $ctx->res->content_type('text/plain')->status(204) },
			'/no_content_with_body' => sub ($self, $ctx) { $ctx->res->status(204)->text('body') },
			'/extra_arguments' => sub ($self, $ctx) { $ctx->res->text('x', status => 201) },
		);

		$self->router->add($_ => {to => $routes{$_}}) for sort keys %routes;
	}
}

my $app = ResponseApp->new;

subtest 'text sends UTF-8 plain text' => sub {
	http $app, GET '/text';
	http_status_is 200;
	http_header_is 'content-type', 'text/plain; charset=utf-8';
	http_text_is "caf\x{e9}";
};

subtest 'text stringifies an object' => sub {
	http $app, GET '/text_object';
	http_status_is 200;
	http_text_is 'stringified object';
};

subtest 'html sends UTF-8 HTML' => sub {
	http $app, GET '/html';
	http_status_is 200;
	http_header_is 'content-type', 'text/html; charset=utf-8';
	http_text_is '<p>hi</p>';
};

subtest 'json sends JSON without a charset' => sub {
	http $app, GET '/json';
	http_status_is 200;
	http_header_is 'content-type', 'application/json';
	is http->json, {ok => 1}, 'body ok';
};

subtest 'redirect defaults to 302' => sub {
	http $app, GET '/redirect';
	http_status_is 302;
	http_header_is 'location', '/target';
};

subtest 'redirect takes a status' => sub {
	http $app, GET '/redirect_301';
	http_status_is 301;
	http_header_is 'location', '/target';
};

subtest 'redirect replaces an earlier status' => sub {
	http $app, GET '/redirect_after_status';
	http_status_is 302;
};

subtest 'status_try keeps a status already set' => sub {
	http $app, GET '/status_try';
	http_status_is 201;
	http_text_is 'kept';
};

subtest 'status reads 200 when unset' => sub {
	http $app, GET '/status_default';
	http_text_is '200';
};

subtest 'an explicit content type wins and gets a charset' => sub {
	http $app, GET '/explicit_type';
	http_header_is 'content-type', 'application/xml; charset=utf-8';
	http_text_is '<a/>';
};

subtest 'an explicit charset is kept' => sub {
	http $app, GET '/explicit_charset';
	http_header_is 'content-type', 'text/csv; charset=latin1';
};

subtest 'a JSON content type gets no charset' => sub {
	http $app, GET '/json_type';
	http_header_is 'content-type', 'application/vnd.api+json';
};

subtest 'header adds a response header' => sub {
	http $app, GET '/header';
	http_header_is 'x-example', 'one';
	http_text_is 'h';
};

subtest 'a Content-Type set through header is kept' => sub {
	http $app, GET '/header_content_type';
	http_header_is 'content-type', 'text/x-custom';
};

subtest 'a bodiless status sends no content type' => sub {
	http $app, GET '/no_content';
	http_status_is 204;
	is http->header('content-type'), undef, 'no content-type';
	is http->content, '', 'no body';
};

subtest 'a body with a bodiless status dies at respond' => sub {
	like dies { http $app, GET '/no_content_with_body' },
		qr/response body is forbidden for status 204/, 'exception ok';
};

subtest 'extra arguments to a body method die' => sub {
	http $app, GET '/extra_arguments';
	http_status_is 500;
	like http->text, qr/Too many arguments/, 'error ok';
};

done_testing;
