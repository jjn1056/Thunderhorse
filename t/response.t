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
	use Future::AsyncAwait;

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
			'/header_content_type_lc' => sub ($self, $ctx) {
				$ctx->res->header('content-type' => 'text/csv')->text('a,b')
			},
			'/header_json_type' => sub ($self, $ctx) {
				$ctx->res->header('Content-Type' => 'application/json')->text('{}')
			},
			'/content_type_undef' => sub ($self, $ctx) { $ctx->res->content_type(undef)->text('u') },
			'/header_type_redirect' => sub ($self, $ctx) {
				$ctx->res->header('Content-Type' => 'text/x-r')->redirect('/to')
			},
			'/type_redirect' => sub ($self, $ctx) { $ctx->res->content_type('text/x-r')->redirect('/to') },
			'/header_undef_type' => sub ($self, $ctx) { $ctx->res->header('Content-Type' => undef)->text('a') },
			'/no_content' => sub ($self, $ctx) { $ctx->res->content_type('text/plain')->status(204) },
			'/no_content_with_body' => sub ($self, $ctx) { $ctx->res->status(204)->text('body') },
			'/extra_arguments' => sub ($self, $ctx) { $ctx->res->text('x', status => 201) },
			'/unencodable' => sub ($self, $ctx) { $ctx->res->json({x => sub { 1 }}) },
			'/send_res_unset' => async sub ($self, $ctx) {
				$ctx->res->header('X-Only' => 'yes');
				await $ctx->send_res;
			},
		);

		$self->router->add($_ => {to => $routes{$_}}) for sort keys %routes;
	}
}

my $app = ResponseApp->new;
my @errors;
$app->add_hook(error => sub ($controller, $ctx, $error) { push @errors, "$error" });

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

subtest 'a Content-Type set through header gets the charset, as through content_type' => sub {
	http $app, GET '/header_content_type';
	http_header_is 'content-type', 'text/x-custom; charset=utf-8';
	http $app, GET '/header_content_type_lc';
	http_header_is 'content-type', 'text/csv; charset=utf-8';
	http $app, GET '/header_json_type';
	http_header_is 'content-type', 'application/json';
};

subtest 'a Content-Type set before a redirect is kept' => sub {
	for my $path ('/header_type_redirect', '/type_redirect') {
		http $app, GET $path;
		http_status_is 302;
		http_header_is 'location', '/to';
		http_header_is 'content-type', 'text/x-r';
	}
};

subtest 'an undefined Content-Type header value is an error' => sub {
	@errors = ();
	http $app, GET '/header_undef_type';
	http_status_is 500;
	is scalar(@errors), 1, 'error hook fired';
};

subtest 'content_type(undef) leaves the body default in place' => sub {
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	http $app, GET '/content_type_undef';
	http_header_is 'content-type', 'text/plain; charset=utf-8';
	is \@warnings, [], 'no warnings';
};

subtest 'a bodiless status sends no content type' => sub {
	http $app, GET '/no_content';
	http_status_is 204;
	is http->header('content-type'), undef, 'no content-type';
	is http->content, '', 'no body';
};

subtest 'a response that cannot be built goes through error handling' => sub {
	@errors = ();

	http $app, GET '/no_content_with_body';
	http_status_is 500;
	like http->text, qr/response body is forbidden for status 204/, 'bodiless status error page';

	http $app, GET '/unencodable';
	http_status_is 500;
	like http->text, qr/encountered CODE/, 'unencodable JSON error page';

	is scalar(@errors), 2, 'error hook fired for both';
};

subtest 'send_res without a status sends 200' => sub {
	http $app, GET '/send_res_unset';
	http_status_is 200;
	http_header_is 'x-only', 'yes';
	is http->content, '', 'no body';
};

subtest 'extra arguments to a body method die' => sub {
	http $app, GET '/extra_arguments';
	http_status_is 500;
	like http->text, qr/Too many arguments/, 'error ok';
};

done_testing;
