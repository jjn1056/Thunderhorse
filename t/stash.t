use v5.40;
use Test2::V1 -ipP;
use Test2::Thunderhorse;
use Future::AsyncAwait;
use HTTP::Request::Common;
use PAGI::Stash;

################################################################################
# This tests whether a stash value stored by a controller reaches a middleware
# above it
################################################################################

my $seen;

package StashApp {
	use Mooish::Base -standard;

	extends 'Thunderhorse::App';

	sub build ($self)
	{
		# reads the stash after the controllers return, as a logger would
		$self->add_middleware(
			sub ($app) {
				async sub ($scope, $receive, $send) {
					await $app->($scope, $receive, $send);
					$seen = PAGI::Stash->new($scope)->get('user');
				};
			}
		);

		$self->router->add(
			'/test' => {
				to => 'test',
			}
		);
	}

	sub test ($self, $ctx)
	{
		$ctx->stash->set(user => 'alice');
		return 'success';
	}
}

subtest 'should share the stash with middleware added above the controllers' => sub {
	http StashApp->new, GET '/test';
	http_status_is 200;
	is $seen, 'alice', 'middleware sees what the controller stored';
};

done_testing;
