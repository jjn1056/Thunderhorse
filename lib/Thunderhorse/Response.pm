package Thunderhorse::Response;

use v5.40;
use Mooish::Base -standard;
use Future::AsyncAwait;

use Gears::X::Thunderhorse;

extends 'PAGI::ResponseBuilder';
with 'Thunderhorse::Message';

# NOTE: behaviour inherited from PAGI::ResponseBuilder that differs from the
# PAGI::Response builder (PAGI-Tools 0.002) this class extended before:
# - json() leaves key order unspecified (it was canonical, sorted)
# - cookie() sends path=/ by default and lower-case attribute names, and URI-
#   escapes the value; delete_cookie() sends expires as well as max-age
# - empty() is a 200 unless a status was set (it was 204)
# - a redirect's status belongs to the redirect: choosing another body after
#   it uses the status set with status(), or 200 (the 302 used to stick)
# - header_all() returns an array reference (it was a list)
# - text() and html() take only defined strings (references were stringified)
# - send_file() is file(); cors() is gone, PAGI::Middleware::CORS does it

sub FOREIGNBUILDARGS ($class, %args)
{
	Gears::X::Thunderhorse->raise('no context for response')
		unless $args{context};

	# the builder takes no constructor arguments
	return;
}

sub update ($self, $scope, $receive, $send)
{
	# the builder holds no scope: respond() takes it from the context
	return;
}

sub _allows_empty_body ($self, $status)
{
	# HTTP protocol hardcodes - these statuses can have empty bodies
	return $status < 200
		|| $status == 204
		|| ($status >= 300 && $status < 400);
}

sub is_ready ($self)
{
	return true if $self->has_body_source;

	return $self->_allows_empty_body($self->status)
		if $self->has_status;

	return false;
}

# NOTE: PAGI-Tools sends any response as an application:
# $res->to_app->($scope, $receive, $send). This method only keeps
# Context::send_res and try_send_res unchanged, which is the least disruptive
# port. Following the PAGI-Tools way instead, those two call sites would call
# $self->res->to_app->($self->scope, $self->receiver, $self->sender), and this
# method could go.
async sub respond ($self, $send)
{
	my $context = $self->context;
	await $self->to_app->($context->scope, $context->receiver, $send);

	return;
}

__END__

=head1 NAME

Thunderhorse::Response - Response wrapper for Thunderhorse

=head1 SYNOPSIS

	async sub show ($self, $ctx, $id)
	{
		$ctx->res->text("Hello World");
		$ctx->res->json({data => 'value'});
		$ctx->res->redirect('/login');
	}

=head1 DESCRIPTION

Thunderhorse::Response is a thin wrapper around L<PAGI::ResponseBuilder> that
integrates with L<Thunderhorse::Context>. It provides a fluent interface for
building HTTP responses, including JSON, HTML, redirects, and file
downloads.

This class extends L<PAGI::ResponseBuilder> and mixes in
C<Thunderhorse::Message> to provide context integration.

=head1 INTERFACE

Inherits all interface from L<PAGI::ResponseBuilder>, and adds the interface
documented below.

=head2 Attributes

=head3 context

The L<Thunderhorse::Context> object for this request (weakened).

I<Required in the constructor>

=head2 Methods

=head3 new

	$object = $class->new(%args)

Standard Mooish constructor. Consult L</Attributes> section for available
constructor arguments.

=head3 update

	$res->update($scope, $receive, $send)

Called automatically when the context's PAGI tuple changes via setter of
L<Thunderhorse::Context/pagi>. The response holds no PAGI scope, so this does
nothing; L</respond> takes the scope from the context.

=head3 is_ready

	$bool = $res->is_ready()

Returns whether this response is ready as far as Thunderhorse is concerned.
Responses which are ready will cause the context to become consumed after the
route handler returns.

Response is ready if it has a body, or if it has a status which does not
require body like C<204 No Content> or C<3XX>.

=head3 respond

	await $res->respond($send)

Sends the response with the context's scope and receiver and the given
C<$send>. L<Thunderhorse::Context/send_res> calls it.

=head1 SEE ALSO

L<Thunderhorse>, L<PAGI::ResponseBuilder>, L<Thunderhorse::Context>
