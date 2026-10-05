package FullApp::Controller::API;

use v5.40;
use Mooish::Base;
use Future::AsyncAwait;
use PAGI::Response qw(response);

extends 'Thunderhorse::Controller';

sub build ($self)
{
	$self->router->add(
		'/locations' => {
			to => 'list_locations',
			name => 'location_list_api',
			action => 'http.get',
		}
	);

	$self->router->add(
		'/locations/count' => {
			to => 'count_locations',
			name => 'location_count_api',
			action => 'http.get',
		}
	);
}

sub flatten_locations ($self, $level)
{
	my @out;
	foreach my $loc ($level->locations->@*) {
		push @out, $loc, $self->flatten_locations($loc);
	}

	return @out;
}

sub list_locations ($self, $ctx)
{
	my @locations = map {
		+{
			pattern => $_->pattern,
			controller => ref $_->controller,
			handler => ref $_->to eq 'CODE' ? '<anonymous>' : $_->to,
			name => $_->name,
			action => $_->action,
		}
	} $self->flatten_locations($self->router);

	$ctx->res->json(\@locations);
}

# A handler may return a complete PAGI response value instead of using $ctx->res.
sub count_locations ($self, $ctx)
{
	my @locations = $self->flatten_locations($self->router);
	return response('JSON', {count => scalar @locations});
}
