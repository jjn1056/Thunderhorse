package Thunderhorse::Response;

use v5.40;
use Mooish::Base -standard;

use Devel::StrictMode;
use Future::AsyncAwait;
use PAGI::Response qw(response);

with 'Thunderhorse::Message';

has field '_status' => (
	(STRICT ? (isa => Int) : ()),
	writer => 1,
	predicate => 'has_status',
);

has field '_content_type' => (
	(STRICT ? (isa => Str) : ()),
	writer => 1,
	predicate => 1,
);

has field '_headers' => (
	(STRICT ? (isa => ArrayRef) : ()),
	default => sub { [] },
);

# [response class name, body] for the response built at respond time; the
# last body set wins, so setting one replaces a response value
has field '_body' => (
	(STRICT ? (isa => Tuple [Str, Any]) : ()),
	writer => 1,
	predicate => 1,
	trigger => sub ($self, @) { $self->_clear_value },
);

# a complete response value set with value(); sent instead of the fields above
has field '_value' => (
	(STRICT ? (isa => InstanceOf ['PAGI::Response']) : ()),
	writer => 1,
	predicate => 1,
	clearer => 1,
);

sub update ($self, $scope, $receive, $send)
{
	return;
}

sub status ($self, @code)
{
	return $self->has_status ? $self->_status : 200
		unless @code;

	$self->_set_status($code[0]);
	return $self;
}

sub status_try ($self, $code)
{
	$self->_set_status($code)
		unless $self->has_status;

	return $self;
}

sub content_type ($self, @type)
{
	return $self->_content_type
		unless @type;

	$self->_set_content_type($type[0]);
	return $self;
}

sub header ($self, $name, $value)
{
	push $self->_headers->@*, $name, $value;
	return $self;
}

sub text ($self, $text)
{
	$self->_set_body(['Text', '' . ($text // '')]);
	return $self;
}

sub html ($self, $html)
{
	$self->_set_body(['HTML', '' . ($html // '')]);
	return $self;
}

sub json ($self, $data)
{
	$self->_set_body(['JSON', $data]);
	return $self;
}

sub redirect ($self, $url, $status = 302)
{
	$self->_set_status($status);
	$self->_set_body(['Redirect', $url]);
	return $self;
}

sub value ($self, $response)
{
	$self->_set_value($response);
	return $self;
}

sub has_body_source ($self)
{
	return $self->_has_value || $self->_has_body;
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

async sub respond ($self, $send)
{
	my $context = $self->context;
	await $self->_response_value->to_app->($context->scope, $context->receiver, $send);
	return;
}

sub _response_value ($self)
{
	return $self->_value
		if $self->_has_value;

	my @status = $self->has_status ? (status => $self->_status) : ();
	my @headers = $self->_headers->@*;

	return response('Empty', status => $self->status, headers => [_without_content_type(@headers)])
		unless $self->_has_body;

	my ($class, $body) = $self->_body->@*;
	return response('Redirect', $body, @status, headers => \@headers)
		if $class eq 'Redirect';

	my @content_type = $self->_has_content_type
		? (content_type => _with_charset($self->_content_type))
		: ();

	return response($class, $body, @status, @content_type, headers => \@headers);
}

# Bodies are sent as UTF-8, so a text content type without a charset says so.
# JSON is UTF-8 by definition and takes no charset parameter.
sub _with_charset ($type)
{
	return $type if $type =~ m{charset=}i;

	my ($media) = $type =~ m{^\s*([^;]+)};
	$media =~ s{\s+\z}{};
	return $type if lc $media eq 'application/json' || $media =~ m{\+json\z}i;

	return "$type; charset=utf-8";
}

# A response without a body carries no content type.
sub _without_content_type (@headers)
{
	my @kept;
	for (my $index = 0; $index < @headers; $index += 2) {
		push @kept, @headers[$index, $index + 1]
			unless lc $headers[$index] eq 'content-type';
	}

	return @kept;
}

__END__

=head1 NAME

Thunderhorse::Response - Response builder for Thunderhorse

=head1 SYNOPSIS

	async sub show ($self, $ctx, $id)
	{
		$ctx->res->text("Hello World");
		$ctx->res->json({data => 'value'});
		$ctx->res->redirect('/login');
	}

=head1 DESCRIPTION

Thunderhorse::Response collects a response for the current request: a status,
headers, a content type and a body. When the route handler returns,
Thunderhorse turns it into a L<PAGI::Response> value and sends it. Every setter
returns the response object, so calls can be chained.

The body methods set the body; the last one called wins. A body is sent as
UTF-8.

=head1 INTERFACE

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
L<Thunderhorse::Context/pagi>. A response holds no per-tuple state, so it does
nothing.

=head3 status

	$res = $res->status($code)
	$code = $res->status

Sets the response status. Without an argument, returns the status, or C<200>
when none was set.

=head3 has_status

	$bool = $res->has_status

Returns whether a status was set.

=head3 status_try

	$res = $res->status_try($code)

Sets the status only if none was set yet.

=head3 content_type

	$res = $res->content_type($type)
	$type = $res->content_type

Sets the content type, which wins over the body's own default. A text type
without a C<charset> parameter is sent with C<; charset=utf-8>; a JSON type is
sent as it is. Without an argument, returns the content type that was set, or
C<undef>.

=head3 header

	$res = $res->header($name, $value)

Adds a response header.

=head3 text

	$res = $res->text($text)

Sets a plain-text body, by default C<text/plain; charset=utf-8>. A non-string,
such as an exception object, is stringified.

=head3 html

	$res = $res->html($html)

Sets an HTML body, by default C<text/html; charset=utf-8>. A non-string is
stringified.

=head3 json

	$res = $res->json($data)

Sets a JSON body encoded from C<$data>, by default C<application/json>. Object
member order is unspecified.

=head3 redirect

	$res = $res->redirect($url, $status = 302)

Redirects to C<$url>, replacing any status set earlier. C<$status> must be
C<301>, C<302>, C<303>, C<307> or C<308>.

=head3 value

	$res = $res->value($response)

Sends C<$response>, a complete L<PAGI::Response> value such as one built with
C<response> from L<PAGI::Response>, exactly as it is. Status, headers and
content type set on this object before or after are not sent; a body method
called after it (L</text>, L</html>, L</json>, L</redirect>) replaces it, as
the last body set wins. This is how to send a file, a stream or any other
response this class does not build itself.

=head3 has_body_source

	$bool = $res->has_body_source

Returns whether a body or a response value was set.

=head3 is_ready

	$bool = $res->is_ready()

Returns whether this response is ready as far as Thunderhorse is concerned.
Responses which are ready will cause the context to become consumed after the
route handler returns.

Response is ready if it has a body, or if it has a status which does not
require body like C<204 No Content> or C<3XX>.

=head3 respond

	await $res->respond($send)

Builds the L<PAGI::Response> value and sends it with C<$send>. A status that
forbids a body (C<1xx>, C<204>, C<205>, C<304>) together with a body dies here.
Thunderhorse calls this through L<Thunderhorse::Context/send_res> and
L<Thunderhorse::Context/try_send_res>.

=head1 SEE ALSO

L<Thunderhorse>, L<PAGI::Response>, L<Thunderhorse::Context>
