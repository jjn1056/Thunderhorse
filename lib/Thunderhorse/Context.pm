package Thunderhorse::Context;

use v5.40;
use Mooish::Base -standard;

use Devel::StrictMode;

use Future::AsyncAwait;
use Thunderhorse::Request;
use Thunderhorse::Response qw(response);
use Thunderhorse::WebSocket;
use Thunderhorse::SSE;
use PAGI::Stash;
use PAGI::Session;
use PAGI::Utils qw(invoke_app);

extends 'Gears::Context';

has param 'pagi' => (
	(STRICT ? (isa => Tuple [HashRef, CodeRef, CodeRef]) : ()),
	writer => -hidden,
);

# match structure is recursive
has field 'match' => (
	(STRICT ? (isa => (InstanceOf ['Gears::Router::Match']) | ArrayRef) : ()),
	writer => 1,
);

has field 'req' => (
	(STRICT ? (isa => InstanceOf ['Thunderhorse::Request']) : ()),
	default => sub ($self) { Thunderhorse::Request->new(context => $self) },
);

has field 'connection' => (
	(STRICT ? (isa => HasMethods ['response_started']) : ()),
	lazy => sub ($self) { $self->scope->{'pagi.connection'} },
);

# NOTE: websocket must be lazy, because it will die if scope is not websocket
has field 'ws' => (
	(STRICT ? (isa => InstanceOf ['Thunderhorse::WebSocket']) : ()),
	predicate => 1,
	lazy => sub ($self) { Thunderhorse::WebSocket->new(context => $self) },
);

# NOTE: sse must be lazy, because it will die if scope is not sse
has field 'sse' => (
	(STRICT ? (isa => InstanceOf ['Thunderhorse::SSE']) : ()),
	predicate => 1,
	lazy => sub ($self) { Thunderhorse::SSE->new(context => $self) },
);

has field 'stash' => (
	(STRICT ? (isa => InstanceOf ['PAGI::Stash']) : ()),
	lazy => sub ($self) { PAGI::Stash->new($self) },
);

has field 'session' => (
	(STRICT ? (isa => InstanceOf ['PAGI::Session']) : ()),
	lazy => sub ($self) { PAGI::Session->new($self) },
);

has field '_consumed' => (
	(STRICT ? (isa => Bool) : ()),
	writer => 1,
	default => false,
);

# the response this request will be answered with, once one is chosen
has field '_chosen' => (
	writer => '_set_chosen',
	predicate => '_has_chosen',
	clearer => '_clear_chosen',
);

has field '_error_handled' => (
	(STRICT ? (isa => Bool) : ()),
	writer => '_set_error_handled',
	default => false,
);

sub update ($self, $scope, $receive, $send)
{
	$self->_set_pagi([$scope, $receive, $send]);

	$self->req->update($scope, $receive, $send);

	$self->ws->update($scope, $receive, $send)
		if $self->has_ws;

	$self->sse->update($scope, $receive, $send)
		if $self->has_sse;

	return;
}

sub scope ($self)
{
	return $self->pagi->[0];
}

sub receiver ($self)
{
	return $self->pagi->[1];
}

sub sender ($self)
{
	return $self->pagi->[2];
}

sub consume ($self)
{
	$self->_set_consumed(true);
	return $self;
}

sub is_consumed ($self)
{
	return $self->_consumed
		|| $self->connection->response_started
		|| $self->_has_chosen
		|| ($self->has_ws && $self->ws->is_closed)
		|| ($self->has_sse && $self->sse->is_closed);
}

sub _choose_response ($self, $value)
{
	Gears::X::Thunderhorse->raise('a response must be a PAGI application (an object with to_app)')
		unless blessed $value && $value->can('to_app');

	$self->_set_chosen($value);
	return $value;
}

async sub send_res ($self)
{
	# NOTE: we check a general pagi constraint, but raise a thunderhorse exception -
	# should it just die()?
	Gears::X::Thunderhorse->raise('response was already sent')
		if $self->connection->response_started;

	my $response = $self->_has_chosen ? $self->_chosen : response('Empty', status => 200);
	await invoke_app($response, $self->pagi->@*);

	return;
}

async sub try_send_res ($self)
{
	# PAGI requires sse.close to end a stream; handlers may just return
	if ($self->has_sse && $self->sse->is_started && !$self->sse->is_closed) {
		await $self->sse->close;
		return;
	}

	return
		if $self->connection->response_started;

	await invoke_app($self->_chosen, $self->pagi->@*)
		if $self->_has_chosen;

	return;
}

# The page for an error, from on_error: at most once per request, so a broken
# error page propagates instead of recursing.
async sub _handle_error ($self, $controller, $error)
{
	die $error if $self->_error_handled;
	$self->_set_error_handled(true);
	$self->_clear_chosen;

	my $page = $controller->_on_error($self, $error);
	$page = await $page while $page isa 'Future';

	unless (blessed $page && $page->can('to_app')) {
		# an on_error that answered with render_error but did not return the page
		return $self->_chosen if $self->_has_chosen;

		warn "on_error returned no PAGI application\n";
		$page = response('Text', 'Internal Server Error', status => 500);
	}

	return $page;
}

# Sends the chosen response. A failure before the response starts is answered
# with an error page; after it, it is rethrown.
async sub _send_guarded ($self, $controller)
{
	try {
		await $self->try_send_res;
	}
	catch ($ex) {
		die $ex if $self->connection->response_started;
		$self->_choose_response(await $self->_handle_error($controller, $ex));
		await $self->try_send_res;
	}

	return;
}

__END__

=head1 NAME

Thunderhorse::Context - Request handling context

=head1 SYNOPSIS

	async sub show ($self, $ctx, $id)
	{
		my $query_param = $ctx->req->query('name');
		my $stashed_value = $ctx->stash->get('key');
		my $session_value = $ctx->session->get('key');

		return response('Text', 'Hello World');
	}

=head1 DESCRIPTION

Thunderhorse::Context represents the context of a single HTTP request. It
extends L<Gears::Context> and provides access to the request, response,
WebSocket connection, and Server-Sent Events stream. Each context manages the
lifecycle of request processing.

The context object is passed to route handlers and provides the primary
interface for interacting with the HTTP request and generating responses.

Since this object is created for every request, costly type checks are disabled
conditionally with the help of L<Devel::StrictMode>. Refer to its documentation
to learn how they can be enabled on demand.

=head1 INTERFACE

Inherits all interface from L<Gears::Context>, and adds the interface
documented below.

=head2 Attributes

=head3 pagi

A tuple C<[HashRef, CodeRef, CodeRef]> containing the PAGI scope hash,
receiver, and sender.

I<Required in the constructor>

=head3 match

The router match object (L<Gears::Router::Match>) or array ref containing
match information for the current route.

B<writer:> C<set_match>

=head3 req

The L<Thunderhorse::Request> object for this context. Created automatically
with a reference to this context.

=head3 ws

The L<Thunderhorse::WebSocket> object for this context. Created lazily when
first accessed and will throw an exception if the PAGI scope is not a
WebSocket scope.

B<predicate:> C<has_ws>

=head3 sse

The L<Thunderhorse::SSE> object for this context. Created lazily when first
accessed and will throw an exception if the PAGI scope is not a Server-Sent
Events scope.

B<predicate:> C<has_sse>

=head3 stash

The L<PAGI::Stash> object for this context. Created lazily when first accessed.

=head3 session

The L<PAGI::Session> object for this context. Created lazily when first
accessed.

Note that for session to work properly, L<PAGI::Middleware::Session> must be
used, or other middleware that will populate C<pagi.session> scope key.
L<PAGI::Session> will throw an exception if C<pagi.session> is not present in
scope.

=head3 connection

Connection object for this context, taken from PAGI scope. Connection objects
are inserted into the scope by the server, and there is no clear subclass they
will inherit from. They follow a duck-typed interface though, and can be
trusted to have at least C<response_started> method.

=head2 Methods

=head3 new

	$object = $class->new(%args)

Standard Mooish constructor. Consult L</Attributes> section for available
constructor arguments.

=head3 scope

	$scope = $ctx->scope()

Returns the PAGI scope hash (the first element of the PAGI tuple).

=head3 receiver

	$receiver = $ctx->receiver()

Returns the PAGI receiver callback (the second element of the PAGI tuple).

=head3 sender

	$sender = $ctx->sender()

Returns the PAGI sender callback (the third element of the PAGI tuple).

=head3 update

	$ctx->update($scope, $receive, $send)

Updates PAGI tuple elements in the context and in all subobjects (request,
response, sse, websocket). This is done automatically before a route handler is
called.

=head3 consume

	$ctx->consume()

Marks the context as consumed, preventing further processing. Returns the
context object for chaining.

=head3 is_consumed

	$bool = $ctx->is_consumed()

Returns true if the context has been consumed either explicitly via
L</consume>, or implicitly by sending a response, closing a WebSocket
connection, or closing an SSE stream.

=head3 send_res

	await $ctx->send_res()

Sends the response chosen for this request (see
L<Thunderhorse::App/render_error>), or an empty C<200> if none was chosen. Dies
if a response has already been sent. Handlers normally just return their
response.

=head3 try_send_res

	$ctx->try_send_res()

Similar as L</send_res>, but does nothing if the response has already been
sent. Also does nothing if no response was chosen.

If the handler started a Server-Sent Events stream and left it open, closes the
stream instead, since PAGI requires an explicit close to end one.

Note that you don't have to use this method explicitly. Thunderhorse will
automatically use it after the route handler returns.

=head1 SEE ALSO

L<Thunderhorse>, L<Gears::Context>, L<Thunderhorse::Request>,
L<Thunderhorse::Response> (C<response>), L<Thunderhorse::WebSocket>, L<Thunderhorse::SSE>

