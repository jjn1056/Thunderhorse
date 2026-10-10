package Thunderhorse::Response;

use v5.40;

use Exporter qw(import);
use PAGI::Response ();

our @EXPORT_OK = qw(response);

# Errors from response() are the caller's: report them at the caller's line.
$Carp::Internal{'Thunderhorse::Response'}++;

my %own_class;

sub response ($name = undef, @args)
{
	return PAGI::Response::response($name, @args)
		unless defined $name && !ref $name && $name =~ m{\A\w+(?:::\w+)*\z};

	my $own = "Thunderhorse::Response::$name";
	$own_class{$name} //= ($own->can('new') || _has_file($own)) ? 1 : 0;

	return PAGI::Response::response($own_class{$name} ? "+$own" : $name, @args);
}

sub _has_file ($class)
{
	(my $file = "$class.pm") =~ s{::}{/}g;
	return 1 if $INC{$file};
	return !!grep { !ref && -f "$_/$file" } @INC;
}

__END__

=head1 NAME

Thunderhorse::Response - Build the responses your handlers return

=head1 SYNOPSIS

	use Thunderhorse::Response qw(response);

	sub show ($self, $ctx, $id)
	{
		return response('JSON', {id => $id});
	}

	sub created ($self, $ctx)
	{
		return response('HTML', $html, status => 201);
	}

=head1 DESCRIPTION

Handlers in Thunderhorse return a complete response, and Thunderhorse sends it.
This module exports C<response>, which builds one by name.

=head1 FUNCTIONS

=head2 response

	$response = response($name, @arguments)

Builds a response. C<$name> is looked up as C<Thunderhorse::Response::$name>
first, then as C<PAGI::Response::$name> (C<Text>, C<HTML>, C<JSON>,
C<Problem>, C<Redirect>, C<Empty>, C<File>, C<Stream>, C<NDJSON>). C<+Exact>
names an exact class. The arguments go to the class's constructor unchanged:
the body first, then C<status>, C<content_type> and C<headers>; see
L<PAGI::Response>.

A class of your own under C<Thunderhorse::Response::> (for example a JSON with
your defaults) is found by the same name, so handlers need not change. A class
that fails to load is reported, never silently replaced by PAGI-Tools' class.

The result is a L<PAGI::Response> value, which any PAGI-Tools component also
accepts.

=head1 SEE ALSO

L<Thunderhorse>, L<PAGI::Response>
