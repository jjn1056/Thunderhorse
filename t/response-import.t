use v5.40;
use Test2::V1 -ipP;
use lib 't/lib';

use Thunderhorse::Response qw(response);

################################################################################
# This tests Thunderhorse::Response, the import point for response values
################################################################################

subtest 'response finds a Thunderhorse class first, then PAGI-Tools' => sub {
	my $teapot = response('Teapot', 'short and stout');
	isa_ok $teapot, ['Thunderhorse::Response::Teapot'], 'Thunderhorse class';
	is $teapot->status, 418, 'its own constructor ran';

	isa_ok response('JSON', {}), ['PAGI::Response::JSON'], 'PAGI-Tools class';
	isa_ok response('+PAGI::Response::Text', 'x'), ['PAGI::Response::Text'], 'exact class';
};

subtest 'a broken Thunderhorse class is reported, not replaced' => sub {
	my $error = dies { response('Broken') };
	like $error, qr/Thunderhorse::Response::Broken/, 'names the class';
	like $error, qr/at \Q${\ __FILE__}\E line \d+/, 'reported at the caller';
};

done_testing;
