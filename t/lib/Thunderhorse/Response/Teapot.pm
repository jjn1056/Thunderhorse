package Thunderhorse::Response::Teapot;

use v5.40;

use parent 'PAGI::Response::Text';

# A Thunderhorse-namespace response class, for the import point's tests.
sub new ($class, @args)
{
	return $class->SUPER::new(@args, status => 418);
}

1;
