package pf::scan::nessus6;

=head1 NAME

pf::scan::nessus6

=cut

=head1 DESCRIPTION

pf::scan::nessus6 is a module to add Nessus v6 scanning option.

=cut

use strict;
use warnings;

use Log::Log4perl;
use Readonly;

use base ('pf::scan');

use pf::config;
use pf::scan;
use pf::util;
use pf::node;
use pf::constants::scan qw($SCAN_VID $PRE_SCAN_VID $POST_SCAN_VID $STATUS_STARTED);
use Net::Nessus::REST;

sub description { 'Nessus6 Scanner' }

=head1 SUBROUTINES

=over   

=item new

Create a new Nessus6 scanning object with the required attributes

=cut

sub new {
    my ( $class, %data ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    $logger->debug("Instantiating a new pf::scan::nessus scanning object");

    my $this = bless {
            '_id'          => undef,
            '_host'        => undef,
            '_port'        => undef,
            '_username'    => undef,
            '_password'    => undef,
            '_scanIp'      => undef,
            '_scanMac'     => undef,
            '_report'      => undef,
            '_file'        => undef,
            '_policy'      => undef,
            '_type'        => undef,
            '_status'      => undef,
            '_scannername' => undef,
	    '_format'	   => 'csv',
    }, $class;

    foreach my $value ( keys %data ) {
        $this->{'_' . $value} = $data{$value};
    }

    return $this;
}

=item startScan

=cut

# WARNING: A lot of extra single quoting has been done to fix perl taint mode issues: #1087
sub startScan {
    my ( $this ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # nessus scan setup
    my $id                  = $this->{_id};
    my $hostaddr            = $this->{_scanIp};
    my $mac                 = $this->{_scanMac};
    my $host                = $this->{_ip};
    my $port                = $this->{_port};
    my $user                = $this->{_username};
    my $pass                = $this->{_password};
    my $nessus_clientpolicy = $this->{_nessus_clientpolicy};
    my $scanner_name        = $this->{_scannername};
    my $format              = $this->{_format};

    my $n = Net::Nessus::REST->new(url => 'https://'.$host.':'.$port);
    $n->create_session(username => $user, password => $pass);
    
    # Verify nessus policy ID on the server, nessus remote scanner id, set scan name and launch the scan
    
    my $polid = $n->get_policy_id(name => $nessus_clientpolicy);
    if ($polid eq "") {
        $logger->warn("Nessus policy doesnt exist ".$nessus_clientpolicy);
        return 1;
    }
    
    my $scannerid = $n->get_scanner_id(name => $scanner_name);
    if ($scannerid eq ""){
    	$logger->warn("Nessus scanner name doesn't exist".$scannerid);
    	return 1;
    }  
    
    #This is neccesary because the way of the new nessus API works, if the scan fails most likely
    # is in this function.
    my $policy_uuid = $n->get_template_id( name => 'custom', type => 'scan');
    if ($policy_uuid eq ""){
    	$logger->warn("Failled to obtain the uuid for the policy".$nessus_clientpolicy);
    	return 1;
    }
    
      
    #Create the scan into the Nessus web server with the name pf-hostaddr-policyname
    my $scanname = "pf-".$hostaddr."-".$nessus_clientpolicy;
    my $scanid = $n->create_scan(
    	uuid => $policy_uuid,
	settings => {
		text_targets => $hostaddr,
		name => $scanname,
		scanner_id => $scannerid,
		policy_id => $polid
	}
    );
    if ( $scanid eq "") {
        $logger->warn("Failled to create the scan");
        return 1;
    }
    
    $n->launch_scan(scan_id => $scanid->{id});
    
    $logger->info("executing Nessus scan with this policy ".$nessus_clientpolicy);
    $this->{'_status'} = $pf::scan::STATUS_STARTED;
    $this->statusReportSyncToDb();
    
   
    # Wait the scan to finish
    my $counter = 0;
    while ($n->get_scan_status(scan_id => $scanid->{id}) ne 'completed') {
        if ($counter > 3600) {
            $logger->info("Nessus scan is older than 1 hour ...");
            return 1;
        }
        $logger->info("Nessus is scanning $hostaddr");
        sleep 15;
        $counter = $counter + 15;
    }
    
    # Get the report
    #$this->{'_report'} = $n->report_filenbe_download($scanid);
    $this->{'_report'} = $n->export_scan(scan_id => $scanid->{id}, format => $format);
    # Remove report on the server and logout from nessus
    $n->delete_scan(scan_id => $scanid->{id});
    $n->DESTROY;
    # Clean the report
    $this->{'_report'} = [ split("\n", $this->{'_report'}) ];

    pf::scan::parse_scan_report($this);
}

=back

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2013 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

1;
