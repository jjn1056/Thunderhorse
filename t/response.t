use v5.40;
use Test2::V1 -ipP;
use Test2::Thunderhorse;
use HTTP::Request::Common;

use Thunderhorse::Response qw(response);

################################################################################
# This tests how Thunderhorse sends the responses handlers return, and how it
# answers errors. The response classes themselves are tested in PAGI-Tools.
################################################################################

package AnswersItself {
	use v5.40;

	sub new ($class) { return bless {}, $class }

	sub to_app ($self)
	{
		return Thunderhorse::Response::response(
			'Text', 'log in first',
			status => 401,
			headers => ['WWW-Authenticate' => 'Basic realm="test"'],
		)->to_app;
	}
}

package SomeApp {
	use v5.40;

	sub new ($class) { return bless {}, $class }
	sub to_app ($self) { return Thunderhorse::Response::response('Text', 'from to_app')->to_app }
}

package ResponseApp {
	use Mooish::Base -standard;
	use Future::AsyncAwait;
	use Thunderhorse::Response qw(response);

	extends 'Thunderhorse::App';

	has field 'reached' => (writer => 1, default => 0);

	sub build ($self)
	{
		my $app = $self;
		my $router = $self->router;
		my %routes = (
			'/to_app' => sub ($self, $ctx) { SomeApp->new },
			'/hashref' => sub ($self, $ctx) { {a => 1} },
			'/coderef' => sub ($self, $ctx) { sub { } },
			'/send_res_unset' => async sub ($self, $ctx) { await $ctx->send_res },
			'/raise_to_app' => sub ($self, $ctx) { die AnswersItself->new },
			'/missing_file' => sub ($self, $ctx) { response('File', '/no/such/file') },
			'/stream_dies' => sub ($self, $ctx) {
				response('Stream', async sub ($writer) { die "producer boom\n" });
			},
			'/answered_then_return' => async sub ($self, $ctx) {
				await $self->render_error($ctx, 403);
				return 'secret';
			},
		);
		$router->add($_ => {to => $routes{$_}}) for sort keys %routes;

		my $guard = $router->add(
			'/guarded' => {
				to => async sub ($self, $ctx) {
					await $self->render_error($ctx, 403)
						unless $ctx->req->query_param('ok');
					return undef;
				}
			}
		);
		$guard->add(
			'/inside' => {
				to => sub ($self, $ctx) {
					$app->set_reached($app->reached + 1);
					return 'inside';
				}
			}
		);
	}
}

package CustomPageApp {
	use Mooish::Base -standard;
	use Future::AsyncAwait;
	use Thunderhorse::Response qw(response);

	extends 'ResponseApp';

	# Gears runs build only when the class itself defines it
	sub build ($self)
	{
		$self->SUPER::build;
	}

	async sub error_page ($self, $controller, $ctx, $code, $message = undef)
	{
		return response('HTML', "<h1>custom $code</h1>", status => $code);
	}
}

package StreamErrorApp {
	use Mooish::Base -standard;
	use Future::AsyncAwait;
	use Thunderhorse::Response qw(response);

	extends 'Thunderhorse::App';

	sub build ($self)
	{
		$self->router->add(
			'/explicit' => {
				to => async sub ($self, $ctx) {
					await $self->render_error($ctx, 500);
					await $ctx->send_res;
				}
			}
		);
	}

	async sub error_page ($self, $controller, $ctx, $code, $message = undef)
	{
		return response('Stream', async sub ($writer) {
			await $writer->write("partial\n");
			die "page stream boom\n";
		}, status => $code);
	}
}

package BrokenPageApp {
	use Mooish::Base -standard;
	use Future::AsyncAwait;
	use Thunderhorse::Response qw(response);

	extends 'Thunderhorse::App';

	has param 'page' => ();

	sub build ($self)
	{
		$self->router->add('/boom' => {to => sub ($self, $ctx) { die "handler boom\n" }});
	}

	async sub error_page ($self, $controller, $ctx, $code, $message = undef)
	{
		die "page broke\n" if $self->page eq 'dies';
		return response('File', '/no/such/file');
	}
}

package FailsafeApp {
	use Mooish::Base -standard;
	use Future::AsyncAwait;

	extends 'Thunderhorse::App';

	sub build ($self)
	{
		$self->router->add('/boom' => {to => sub ($self, $ctx) { die "handler boom\n" }});
	}

	async sub on_error ($self, $controller, $ctx, $error)
	{
		return 'not an application';
	}
}

package RefusingController {
	use Mooish::Base -standard;
	use Future::AsyncAwait;

	extends 'Thunderhorse::Controller';

	sub BUILD ($self, $) { }    # its own BUILD must not skip the check

	async sub render_error ($self, $ctx, $code, $message = undef) { }
}

package main;

my $app = ResponseApp->new;
my @errors;
$app->add_hook(error => sub ($controller, $ctx, $error) { push @errors, "$error" });

subtest 'any value with to_app is sent' => sub {
	http $app, GET '/to_app';
	http_status_is 200;
	http_text_is 'from to_app';
};

subtest 'a plain reference is an error naming the fix' => sub {
	http $app, GET '/hashref';
	http_status_is 500;
	like http->text, qr/cannot render a HASH reference; return response\('JSON'/, 'guidance';
};

subtest 'a bare coderef is an error' => sub {
	http $app, GET '/coderef';
	http_status_is 500;
	like http->text, qr/cannot render a CODE reference/, 'the type is named';
};

subtest 'send_res with nothing chosen sends an empty 200' => sub {
	http $app, GET '/send_res_unset';
	http_status_is 200;
	is http->content, '', 'no body';
};

subtest 'an exception with to_app answers itself' => sub {
	http $app, GET '/raise_to_app';
	http_status_is 401;
	http_header_is 'WWW-Authenticate', 'Basic realm="test"';
	http_text_is 'log in first';
};

subtest 'a missing file fails before the response starts and reaches on_error' => sub {
	@errors = ();
	http $app, GET '/missing_file';
	http_status_is 500;
	like \@errors, [qr/Cannot inspect selected file/], 'error hook saw it';
};

subtest 'a failing stream producer is not answered with a second response' => sub {
	@errors = ();
	like dies { http $app, GET '/stream_dies' }, qr/producer boom/, 'rethrown';
	is \@errors, [], 'on_error was not invoked';
};

subtest 'an explicit send of a failing stream is rethrown, not answered again' => sub {
	like dies { http StreamErrorApp->new, GET '/explicit' }, qr/page stream boom/, 'rethrown';
};

subtest 'render_error answers a bridge, with the default and a custom error_page' => sub {
	for my $case ([ResponseApp => 'Forbidden'], [CustomPageApp => '<h1>custom 403</h1>']) {
		my ($class, $text) = @$case;
		my $guarded = $class->new;

		http $guarded, GET '/guarded/inside';
		http_status_is 403;
		http_text_is $text;
		is $guarded->reached, 0, "$class: the protected location never ran";

		http $guarded, GET '/guarded/inside?ok=1';
		http_status_is 200;
		is $guarded->reached, 1, "$class: an allowed request reaches it";
	}
};

subtest 'a value returned after render_error is ignored' => sub {
	http $app, GET '/answered_then_return';
	http_status_is 403;
	http_text_is 'Forbidden';
};

subtest 'overriding render_error refuses to start' => sub {
	like dies { RefusingController->new(app => $app) },
		qr/render_error is no longer an override point; override error_page/;
};

subtest 'on_error runs at most once: a broken error page propagates' => sub {
	like dies { http BrokenPageApp->new(page => 'file'), GET '/boom' },
		qr/Cannot inspect selected file/;
};

subtest 'a 404 page that fails to build propagates' => sub {
	like dies { http BrokenPageApp->new(page => 'dies'), GET '/nowhere' }, qr/page broke/;
};

subtest 'on_error that returns no application is answered with a 500' => sub {
	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	http FailsafeApp->new, GET '/boom';
	http_status_is 500;
	http_text_is 'Internal Server Error';
	like \@warnings, [qr/on_error returned no PAGI application/], 'warned once';
};

subtest 'an error_page that returns no application is an error, answered once' => sub {
	package NotAnAppPage {
		use Mooish::Base -standard;
		use Future::AsyncAwait;

		extends 'Thunderhorse::App';

		sub build ($self)
		{
			$self->router->add('/boom' => {to => sub { die "handler boom\n" }});
		}

		async sub error_page ($self, @)
		{
			return 'not an application';
		}
	}

	like dies { http NotAnAppPage->new, GET '/boom' }, qr/a response must be a PAGI application/;
};

subtest 'an on_error that calls render_error without returning its page still answers with it' => sub {
	package RenderOnlyOnError {
		use Mooish::Base -standard;
		use Future::AsyncAwait;

		extends 'Thunderhorse::App';

		sub build ($self)
		{
			$self->router->add('/boom' => {to => sub { die "handler boom\n" }});
		}

		async sub on_error ($self, $controller, $ctx, $error)
		{
			await $self->render_error($controller, $ctx, 503, 'down for a moment');
			return;
		}
	}

	my @warnings;
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	http RenderOnlyOnError->new, GET '/boom';
	http_status_is 503;
	http_text_is 'down for a moment';
	is \@warnings, [], 'no failsafe warning';
};

subtest 'a hook override written as a plain sub works' => sub {
	package PlainHooks {
		use Mooish::Base -standard;
		use Thunderhorse::Response qw(response);

		extends 'Thunderhorse::App';

		sub build ($self)
		{
			$self->router->add('/boom' => {to => sub { die "handler boom\n" }});
			$self->router->add('/string' => {to => sub { 'a string' }});
		}

		sub error_page ($self, $controller, $ctx, $code, $message = undef)
		{
			return response('Text', "plain page $code", status => $code);
		}

		sub render_response ($self, $controller, $ctx, $result)
		{
			return response('Text', "plain render: $result");
		}
	}

	my $plain = PlainHooks->new;
	http $plain, GET '/boom';
	http_status_is 500;
	http_text_is 'plain page 500';

	http $plain, GET '/string';
	http_status_is 200;
	http_text_is 'plain render: a string';
};

subtest 'response finds a Thunderhorse class defined without a file' => sub {
	package Thunderhorse::Response::Inline {
		use parent -norequire, 'PAGI::Response::Text';
	}

	isa_ok response('Inline', 'x'), ['Thunderhorse::Response::Inline'];
};

done_testing;
