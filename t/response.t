use v5.40;
use Test2::V1 -ipP;
use Test2::Thunderhorse;
use HTTP::Request::Common;

################################################################################
# This tests Thunderhorse::Response in Thunderhorse: readiness, sending, and
# error handling around it. PAGI::ResponseBuilder's own behaviour (content
# types, redirects, cookies, statuses) is tested in PAGI-Tools.
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
	use Gears::X::HTTP;

	extends 'Thunderhorse::App';

	sub build ($self)
	{
		my %routes = (
			'/text' => sub ($self, $ctx) { $ctx->res->text("caf\x{e9}") },
			'/text_object' => sub ($self, $ctx) { $ctx->res->text(Stringifies->new) },
			'/no_content' => sub ($self, $ctx) { $ctx->res->content_type('text/plain')->status(204) },
			'/no_content_with_body' => sub ($self, $ctx) { $ctx->res->status(204)->text('body') },
			'/unencodable' => sub ($self, $ctx) { $ctx->res->json({x => sub { 1 }}) },
			'/send_res_unset' => async sub ($self, $ctx) {
				$ctx->res->header('X-Only' => 'yes');
				await $ctx->send_res;
			},
			'/raise_object' => sub ($self, $ctx) {
				Gears::X::HTTP->raise(418, 'short and stout');
			},
			'/missing_file' => sub ($self, $ctx) { $ctx->res->file('/no/such/file') },
			'/stream' => sub ($self, $ctx) {
				$ctx->res->stream(async sub ($writer) {
					await $writer->write("one\n");
					await $writer->write("two\n");
				});
			},
			'/stream_dies' => sub ($self, $ctx) {
				$ctx->res->stream(async sub ($writer) { die "producer boom\n" });
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

# PAGI::ResponseBuilder's text() takes only strings; only error pages
# stringify, in render_error, because that is where the value is an exception.
subtest 'an object passed to text is an error' => sub {
	http $app, GET '/text_object';
	http_status_is 500;
	like http->text, qr/defined Unicode scalar/, 'error ok';
};

subtest 'a bodiless status is ready, and sends no content type' => sub {
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

subtest 'an exception object renders as text' => sub {
	http $app, GET '/raise_object';
	http_status_is 418;
	like http->text, qr/short and stout/, 'the message is rendered';
};

subtest 'a missing file fails before the response starts and reaches on_error' => sub {
	@errors = ();
	http $app, GET '/missing_file';
	http_status_is 500;
	like \@errors, [qr/Cannot inspect selected file/], 'error hook saw it';
};

subtest 'stream sends its chunks' => sub {
	http $app, GET '/stream';
	http_status_is 200;
	http_text_is "one\ntwo\n";
};

# A Stream starts the response before its producer runs, so a producer's
# failure is after the start: it is rethrown, never answered with an error page.
subtest 'a failing stream producer is not answered with a second response' => sub {
	@errors = ();
	like dies { http $app, GET '/stream_dies' }, qr/producer boom/,
		'rethrown (Test2::Thunderhorse raises app exceptions)';
	is \@errors, [], 'on_error was not invoked';
};

done_testing;
