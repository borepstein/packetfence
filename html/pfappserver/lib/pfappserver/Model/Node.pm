package pfappserver::Model::Node;

=head1 NAME

pfappserver::Model::Node - Catalyst Model

=head1 DESCRIPTION

Catalyst Model.

=cut

use strict;
use warnings;

use Moose;
use namespace::autoclean;
use Time::localtime;
use Time::Local;

use pf::accounting qw(
    node_accounting_view
    node_accounting_daily_bw node_accounting_weekly_bw node_accounting_monthly_bw node_accounting_yearly_bw
    node_accounting_daily_time node_accounting_weekly_time node_accounting_monthly_time node_accounting_yearly_time
);
use pf::constants;
use pf::config;
use pf::error qw(is_error is_success);
use pf::node;
use pf::nodecategory;
use pf::iplog;
use pf::locationlog;
use Log::Log4perl qw(get_logger);
use pf::node;
use pf::person;
use pf::enforcement qw(reevaluate_access);
use pf::useragent qw(node_useragent_view);
use pf::util;
use pf::config::util;
use pf::violation;

=head1 METHODS

=head2 exists

=cut

sub exists {
    my ( $self, $mac ) = @_;

    my $logger = get_logger();
    my ($status, $result) = ($STATUS::OK);

    eval {
        $result = node_exist($mac);
    };
    if ($@) {
        $result = ["Can't validate node ([_1]) from database.",$mac];
        $status = $STATUS::INTERNAL_SERVER_ERROR;
        $logger->error($@);
    }
    unless ($result) {
        $result = ["Node [_1] was not found.",$mac];
        $status = $STATUS::NOT_FOUND;
        $logger->warn("Node $mac was not found.");
    }

    return ($status, $result);
}

=head2 field_names

Field names to be displayed. The first one is the default sort field.

=cut

sub field_names {
    return [qw(mac detect_date regdate unregdate computername pid last_ip status dhcp_fingerprint category)];
}

=head2 countAll

=cut

sub countAll {
    my ( $self, %params ) = @_;

    my $logger = get_logger();
    my ($status, $status_msg);

    my $count;
    eval {
        my @result = node_count_all(undef, %params);
        $count = pop @result;
    };
    if ($@) {
        $status_msg = "Can't count nodes from database.";
        $logger->error($status_msg);
        return ($STATUS::INTERNAL_SERVER_ERROR, $status_msg);
    }

    return ($STATUS::OK, $count->{nb});
}

=head2 search

Used to perform a simple search

=cut

sub search {
    my ( $self, %params ) = @_;

    my $logger = get_logger();
    my ($status, $status_msg);

    my @nodes;
    eval {
        @nodes = node_view_all(undef, %params);
        @nodes = grep { keys %$_ ? $_ : undef } @nodes;
    };
    if ($@) {
        $status_msg = "Can't fetch nodes from database.";
        $logger->error($status_msg);
        return ($STATUS::INTERNAL_SERVER_ERROR, $status_msg);
    }

    return ($STATUS::OK, \@nodes);
}

=head2 view

From pf::lookup::node::lookup_node()

=cut

sub view {
    my ($self, $mac) = @_;

    my $logger = get_logger();
    my ($status, $status_msg);

    my $node = {};
    eval {
        $node = node_view($mac);
        $node->{vendor} = oui_to_vendor($mac);
        for my $date (qw(regdate unregdate)) {
            my $timestamp = "${date}_timestamp";
            if ($node->{$timestamp}) {
                my @date_data = CORE::localtime($node->{$timestamp});
                $node->{$date} = POSIX::strftime("%Y-%m-%d %H:%M", @date_data);
            }
        }
        foreach (qw[detect_date regdate unregdate]) {
            $node->{$_} = '' if exists $node->{$_} && $node->{$_} eq '0000-00-00 00:00:00';
        }

        # Show 802.1X username only if connection is of type EAP
        my $connection_type = str_to_connection_type($node->{last_connection_type}) if ($node->{last_connection_type});
        unless ($connection_type && ($connection_type & $EAP) == $EAP) {
            delete $node->{last_dot1x_username};
        }

        # Fetch IP information
        $node->{iplog} = pf::iplog::view($mac);

        # Fetch the IP activity of the past 14 days
#        my $start_time = time() - 14 * 24 * 60 * 60;
#        my $end_time = time();
#        my @iplog_history = iplog_history($mac,
#                                              (start_time => $start_time, end_time => $end_time));
#        $node->{iplog}->{history} = \@iplog_history;
#        _graphIplogHistory($node, $start_time, $end_time);

        # Fetch IP address history
        my @iplog_history = iplog_history($mac);
        map { $_->{end_time} = '' if ($_->{end_time} eq '0000-00-00 00:00:00') } @iplog_history;
        $node->{iplog}->{history} = \@iplog_history;

        if ($node->{iplog}->{'ip'}) {
            $node->{iplog}->{active} = 1;
        } else {
            my $last_iplog = pop @iplog_history;
            $node->{iplog}->{ip} = $last_iplog->{ip};
            $node->{iplog}->{end_time} = $last_iplog->{end_time};
        }

        # Fetch switch location history
        my @locationlog_history = locationlog_history_mac($mac);
        #                                                  (start_time => $start_time, end_time => $end_time));
        if (scalar @locationlog_history > 0) {
            $node->{locationlog}->{history} = \@locationlog_history;
        }

        # Fetch user-agent information
        if ($node->{user_agent}) {
            $node->{useragent} = node_useragent_view($mac);
        }

        #    my $node_accounting = node_accounting_view($mac);
        #    if (defined($node_accounting->{'mac'})) {
        #        my $daily_bw = node_accounting_daily_bw($mac);
        #        my $weekly_bw = node_accounting_weekly_bw($mac);
        #        my $monthly_bw = node_accounting_monthly_bw($mac);
        #        my $yearly_bw = node_accounting_yearly_bw($mac);
        #        my $daily_time = node_accounting_daily_time($mac);
        #        my $weekly_time = node_accounting_weekly_time($mac);
        #        my $monthly_time = node_accounting_monthly_time($mac);
        #        my $yearly_time = node_accounting_yearly_time($mac);
        #    }
    };
    if ($@) {
        $status_msg = ["Can't retrieve node ([_1]) from database.",$mac];
        $logger->error($@);
        return ($STATUS::INTERNAL_SERVER_ERROR, $status_msg);
    }

    return ($STATUS::OK, $node);
}

=head2 create

Create and register a node

=cut

sub create {
    my ($self, $data) = @_;

    my $logger = Log::Log4perl::get_logger(__PACKAGE__);
    my ($status, $result) = ($STATUS::CREATED);
    my $mac = $data->{mac};
    my $pid = $data->{pid} || $default_pid;

    # Adding person (using modify in case person already exists)
    $result = node_register($mac, $pid, %{$data});
    if ($result) {
        $logger->info("Created node $mac");
    }
    else {
        return ($STATUS::INTERNAL_SERVER_ERROR, 'Unexpected error. See server-side logs for details.');
    }

    return ($status);
}


=head2 update

See subroutine manage of pfcmd.pl

=cut

sub update {
    my ($self, $mac, $node_ref) = @_;

    my $logger = get_logger();
    my ($status, $result) = ($STATUS::OK);
    my $previous_node_ref;

    $previous_node_ref = node_view($mac);
    if ($previous_node_ref->{status} ne $node_ref->{status}) {
        # Status was modified
        my $option;
        if ($node_ref->{status} eq $pf::node::STATUS_REGISTERED) {
            $option = "register";
            $result = node_register($mac, $previous_node_ref->{pid}, %{$node_ref});
        }
        elsif ($node_ref->{status} eq $pf::node::STATUS_UNREGISTERED) {
            $option = "deregister";
            $result = node_deregister($mac, %{$node_ref});
        }
    }
    unless (defined $result) {
        $node_ref->{pid} ||= $default_pid;
        $result = node_modify($mac, %{$node_ref});
    }
    if ($result) {
        my $category_id = $node_ref->{category_id} || '';
        my $previous_category_id = $previous_node_ref->{category_id} || '';
        if ($previous_node_ref->{status} ne $node_ref->{status} || $previous_category_id ne $category_id) {
            # Node has been registered or deregistered
            # or the role has changed and is not currently using 802.1X
            reevaluate_access($mac, "node_modify");
        }
    }
    else {
        $status = $STATUS::INTERNAL_SERVER_ERROR;
        $result = 'An error occurred while saving the node.';
    }

    return ($status, $result);
}

=head2 import

See pf::import::nodes

=cut

sub importCSV {
    my ($self, $data, $user) = @_;

    my $logger = Log::Log4perl::get_logger(__PACKAGE__);
    my ($status, $message);
    my $filename = $data->{nodes_file}->filename;
    my $tmpfilename = $data->{nodes_file}->tempname;
    my $delimiter = $data->{delimiter};
    my $default_node_pid = $data->{default_pid};
    my $default_category_id = $data->{default_category_id};
    my $default_voip = $data->{default_voip};

    $logger->debug("CSV file import nodes from $tmpfilename ($filename, \"$delimiter\")");

    # Build hash table for columns order
    my $count = 0;
    my $skipped = 0;
    my %index = ();
    foreach my $column (@{$data->{columns}}) {
        if ($column->{enabled} || $column->{name} eq 'mac') {
            # Add checked columns and mandatory columns
            $index{$column->{name}} = $count;
            $count++;
        }
    }

    # Map delimiter to its actual character
    if ($delimiter eq 'comma') {
        $delimiter = ',';
    } elsif ($delimiter eq 'semicolon') {
        $delimiter = ';';
    } elsif ($delimiter eq 'colon') {
        $delimiter = ':';
    } elsif ($delimiter eq 'tab') {
        $delimiter = "\t";
    }

    # Read CSV file
    $count = 0;
    my $has_pid = exists $index{'pid'};
    if (open (my $import_fh, "<", $tmpfilename)) {
        my $csv = Text::CSV->new({ binary => 1, sep_char => $delimiter });
        while (my $row = $csv->getline($import_fh)) {
            my ($pid, $mac, $node, %data, $result);

            if($has_pid) {
                $pid = $row->[$index{'pid'}] || undef;
                if ( $pid && ($pid !~ /$pf::person::PID_RE/ || !person_exist($pid))) {
                    $logger->debug("Ignored unknown PID ($pid)");
                    $skipped++;
                    next;
                }
            }

            $mac = $row->[$index{'mac'}] || undef;
            if (!$mac || !valid_mac($mac)) {
                $logger->debug("Ignored invalid MAC ($mac)");
                $skipped++;
                next;
            }
            $mac = clean_mac($mac);
            $pid ||= $default_node_pid || $default_pid;
            $node = node_view($mac);
            %data =
              (
               'mac'         => $mac,
               'pid'         => $pid,
               'category'    => $index{'category'}  ? $row->[$index{'category'}]  : undef,
               'category_id' => $index{'category'}  ? undef                       : $default_category_id,
               'unregdate'   => $index{'unregdate'} ? $row->[$index{'unregdate'}] : undef,
               'voip'        => $index{'voip'}      ? $row->[$index{'voip'}]      : $default_voip,
               'notes'       => $index{'notes'}     ? $row->[$index{'notes'}]     : undef,
              );
            if (!defined($node) || (ref($node) eq 'HASH' && $node->{'status'} ne $pf::node::STATUS_REGISTERED)) {
                $logger->debug("Register MAC $mac ($pid)");
                $result = node_register($mac, $pid, %data);
            }
            else {
                $logger->debug("Modify already registered MAC $mac ($pid)");
                $result = node_modify($mac, %data);
            }
            if ($result) {
                $count++;
            }
            else {
                $skipped++;
            }
        }
        unless ($csv->eof) {
            $logger->warn("Problem with CSV file importation: " . $csv->error_diag());
            ($status, $message) = ($STATUS::INTERNAL_SERVER_ERROR, ["Problem with importation: [_1]" , $csv->error_diag()]);
        }
        else {
            ($status, $message) = ($STATUS::CREATED, { count => $count, skipped => $skipped });
        }
        close $import_fh;
    }
    else {
        $logger->warn("Can't open CSV file $filename: $@");
        ($status, $message) = ($STATUS::INTERNAL_SERVER_ERROR, "Can't read CSV file.");
    }

    $logger->info("CSV file ($filename) import $count nodes, skip $skipped nodes");

    return ($status, $message);
}

=head2 delete

=cut

sub delete {
    my ($self, $mac) = @_;

    my $logger = get_logger();
    my ($status, $status_msg) = ($STATUS::OK);

    unless (node_delete($mac)) {
        $status = $STATUS::INTERNAL_SERVER_ERROR;
        $status_msg = "The node can't be delete because it's still active.";
    }

    return ($status, $status_msg);
}

=head2 reevaluate

=cut

sub reevaluate {
    my ($self, $mac) = @_;
    my $logger = get_logger();
    my ($status, $status_msg) = ($STATUS::OK);

    unless(reevaluate_access($mac, "node_modify")){
        $status = $STATUS::INTERNAL_SERVER_ERROR;
        $status_msg = "The access couldn't be reevaluated.";
    }

    return ($status, $status_msg);
}

=head2 availableStatus

=cut

sub availableStatus {
    my ( $self ) = @_;

    return [ $pf::node::STATUS_REGISTERED,
             $pf::node::STATUS_UNREGISTERED,
             $pf::node::STATUS_PENDING ];
}

=head2 violations

Return the open violations associated to the MAC.

=cut

sub violations {
    my ($self, $mac) = @_;

    my $logger = get_logger();
    my ($status, $status_msg);

    my @violations;
    eval {
        @violations = violation_view_desc($mac);
        map { $_->{release_date} = '' if ($_->{release_date} eq '0000-00-00 00:00:00') } @violations;
    };
    if ($@) {
        $status_msg = "Can't fetch violations from database.";
        $logger->error($status_msg);
        return ($STATUS::INTERNAL_SERVER_ERROR, $status_msg);
    }

    return ($STATUS::OK, \@violations);
}

=head2 addViolation

=cut

sub addViolation {
    my ($self, $mac, $vid) = @_;

    if (violation_add($mac, $vid)) {
        return ($STATUS::OK, 'The violation was successfully added.');
    }
    else {
        return ($STATUS::INTERNAL_SERVER_ERROR, 'An error occurred while adding the violation.');
    }
}

=head2 closeViolation

=cut

sub closeViolation {
    my ($self, $id) = @_;
    if($self->_closeViolation($id)) {
        return ($STATUS::OK, 'The violation was successfully closed.');
    }
    return ($STATUS::INTERNAL_SERVER_ERROR, 'An error occurred while closing the violation.');
}

=head2 runViolation

=cut

sub runViolation {
    my ($self, $id) = @_;
    if(violation_run_delayed($id)) {
        return ($STATUS::OK, 'The violation was successfully ran');
    }
    return ($STATUS::INTERNAL_SERVER_ERROR, 'An error occurred while running the violation.');
}

=head2 closeViolations

=cut

sub bulkCloseViolations {
    my ($self, @macs) = @_;
    my $count = 0;

    foreach my $mac (@macs) {
        foreach my $violation (violation_view_open_desc($mac)) {
            $count++ if $self->_closeViolation($violation->{id});
        }
    }
    return ($STATUS::OK, ["[_1] violation(s) were closed.",$count]);
}

=head2 _closeViolation

helper function for doing a force close

=cut

sub _closeViolation{
    my ($self,$id) = @_;
    my $result;
    my $violation = violation_exist_id($id);
    if ($violation) {
        if (violation_force_close($violation->{mac}, $violation->{vid})) {
            pf::enforcement::reevaluate_access($violation->{mac}, 'manage_vclose');
            $result = 1;
        }
    }
    return $result;
}

=head2 bulkApplyViolation

=cut

sub bulkApplyViolation {
    my ($self, $violation_id, @macs) = @_;
    my $count = 0;
    foreach my $mac (@macs) {
        my ($last_id) = violation_add( $mac, $violation_id);
        $count++ if $last_id > 0;;
    }
    return ($STATUS::OK, ["[_1] violation(s) were opened.",$count]);
}


=head2 _graphIplogHistory

The associated HTML template to show the graph could look like this:

=begin html

              <h6>Last 2 weeks</h6>
              [%- IF node.iplog.series.size %]
              <div id="iplog" class="chart"></div>
              <script type="text/javascript">
graphs.charts['iplog'] = {
    type: 'dot',
    size: 'large',
    ylabels: ['[% node.iplog.ylabels.join("','") %]'],
    xlabels: ['[% node.iplog.xlabels.join("','") %]'],
    series: {
    [% FOREACH set IN node.iplog.series.keys -%]
      '[% set %]' : [[% node.iplog.series.$set.join(',') %]][% UNLESS loop.last %],[% END %]
    [%- END %]
    }
};
              </script>
              [%- ELSE %]
              <div class="alert alert-warning">
                <strong>Warning!</strong> <span>[% l('This MAC address has not been seen recently.') %]</span>
              </div>
              [%- END %]

=end html

And the corresponding JavaScript:

=begin javascript

                modal.find('a[href="#nodeHistory"]').on('shown', function () {
                    if ($('#nodeHistory .chart').children().length == 0)
                        drawGraphs();
                });

=end javascript

=cut

sub _graphIplogHistory {
    my ($node_ref, $start_time, $end_time) = @_;

    my $logger = get_logger();

    if ($node_ref->{iplog}->{history} && scalar @{$node_ref->{iplog}->{history}}) {
        my $now = localtime();
        my @xlabels = ();
        my @ylabels = ('AM', 'PM');
        my %dates = ();
        my %series = ();

        my ($log, $start_tm, $end_tm);
        foreach $log (@{$node_ref->{iplog}->{history}}) {
            $start_tm = localtime($log->{start_timestamp});
            $end_tm = localtime($log->{end_timestamp});

            $end_tm = $now if (!$log->{end_timestamp} ||
                               $end_tm->year > $now->year ||
                               $end_tm->year == $now->year && $end_tm->mon > $now->mon ||
                               $end_tm->year == $now->year && $end_tm->mon == $now->mon && $end_tm->mday > $now->mday);

            # Split periods in half-days:
            #   AM = 0:00 - 11:59
            #   PM = 12:00 - 23:59
            my $last_hday;
            do {
                $last_hday = 0;
                my $hday = 'AM';
                my $until = 12;

                if ($start_tm->hour >= 12) {
                    $hday = 'PM';
                    $until = 24;
                }
                if ($start_tm->mday == $end_tm->mday &&
                    $start_tm->mon  == $end_tm->mon  &&
                    $start_tm->year == $end_tm->year &&
                    $until > $end_tm->hour) {
                    # This is the last half-day
                    $until = $end_tm->hour;
                    $last_hday = 1;
                }

                my $nb_hours = $until - $start_tm->hour;
                $nb_hours++ unless ($nb_hours > 0);

                my $day = sprintf "%d-%02d-%02d", $start_tm->year+1900, $start_tm->mon+1, $start_tm->mday;
                $dates{$day}          = {} unless ($dates{$day});
                $dates{$day}->{$hday} = 0  unless ($dates{$day}->{$hday});
                $dates{$day}->{$hday} += $nb_hours;

                unless ($last_hday) {
                    # Compute next half-day
                    # The time manipulation is required to not be affected by DST changes
                    my $TIME = timelocal(0, 59, ($until - 1), $start_tm->mday, $start_tm->mon, $start_tm->year+1900);
                    $TIME = $TIME + 60;
                    $start_tm = localtime($TIME);
                }
            } while ($last_hday == 0);
        }

        # Fill the gaps for the period
        $start_tm = localtime($start_time);
        $end_tm = localtime($end_time);

        my $day = sprintf "%d-%02d-%02d", $start_tm->year+1900, $start_tm->mon+1, $start_tm->mday;
        my $end_day = sprintf "%d-%02d-%02d", $end_tm->year+1900, $end_tm->mon+1, $end_tm->mday;

        $series{'AM'} = [];
        $series{'PM'} = [];

        my $last = 0;
        do {
            push(@xlabels, $day);

            foreach my $hday (@ylabels) {
                $dates{$day} = {} unless ($dates{$day});
                unless ($dates{$day}->{$hday}) {
                    $dates{$day}->{$hday} = 0;
                }
                elsif ($dates{$day}->{$hday} > 12) {
                    $dates{$day}->{$hday} = 12 ;
                }
                push(@{$series{$hday}}, $dates{$day}->{$hday});
                $logger->debug("$day $hday : " . $dates{$day}->{$hday});
            }
            if ($day ne $end_day) {
                # Compute next day
                my $TIME = timelocal(0, 0, 12, $start_tm->mday, $start_tm->mon, $start_tm->year+1900);
                $TIME = $TIME + 24 * 60 * 60;
                $start_tm = localtime($TIME);
                $day = sprintf "%d-%02d-%02d", $start_tm->year+1900, $start_tm->mon+1, $start_tm->mday;
            }
            else {
                $last = 1;
            }
        } while ($last == 0);

        $node_ref->{iplog}->{xlabels} = \@xlabels;
        $node_ref->{iplog}->{ylabels} = \@ylabels;
        $node_ref->{iplog}->{series} = \%series;
        delete $node_ref->{iplog}->{history};
    }
}


=head2 bulkRegister

=cut

sub bulkRegister {
    my ($self, @macs) = @_;
    my $count = 0;
    my ($status, $status_msg);
    foreach my $mac (@macs) {
        my $node = node_attributes($mac);
        if ($node->{status} ne $pf::node::STATUS_REGISTERED) {
            $node->{status} = $pf::node::STATUS_REGISTERED;
            $self->update($mac,$node);
            $count++;
        }
    }
    return ($STATUS::OK, ["[_1] node(s) were registered.",$count]);
}

=head2 bulkDeregister

=cut

sub bulkDeregister {
    my ($self, @macs) = @_;
    my $count = 0;
    foreach my $mac (@macs) {
        my $node = node_attributes($mac);
        if ($node->{status} ne $pf::node::STATUS_UNREGISTERED) {
            $node->{status} = $pf::node::STATUS_UNREGISTERED;
            $self->update($mac,$node);
            $count++;
        }
    }
    return ($STATUS::OK, ["[_1] node(s) were deregistered.", $count]);
}

=head2 bulkApplyRole

=cut

sub bulkApplyRole {
    my ($self, $category_id, @macs) = @_;
    my $count = 0;
    my $category = nodecategory_view($category_id);
    my $name = $category->{name};
    foreach my $mac (@macs) {
        my $node = node_view($mac);
        my $old_category_id = $node->{category_id};
        if (!defined($old_category_id) || $old_category_id != $category_id) {
            $node->{category_id} = $category_id;
            $node->{category} = $name;
            # Role has changed
            $self->update($mac, $node);
            $count++;
        }
    }
    return ($STATUS::OK, ["Role was changed for [_1] node(s)", $count]);
}

=head2 bulkApplyBypassRole

=cut

sub bulkApplyBypassRole {
    my ($self, $role, @macs) = @_;
    my $count = 0;
    foreach my $mac (@macs) {
        my $node = node_view($mac);
        my $old_bypass_role_id = $node->{bypass_role_id};
        if (!defined($old_bypass_role_id) || $old_bypass_role_id != $role) {
            # Role has changed
            $node->{bypass_role_id} = $role;
            $self->update($mac,$node);
            $count++;
        }
    }
    return ($STATUS::OK, ["Bypass Role was changed for [_1] node(s)", $count]);
}

=head2 bulkReevaluateAccess

=cut

sub bulkReevaluateAccess {
    my ($self, @macs) = @_;
    my $count = 0;
    foreach my $mac (@macs) {
        if (reevaluate_access($mac, "node_modify")){
            $count++;
        }
    }
    return ($STATUS::OK, ["Access was reevaluated for [_1] node(s)", $count]);
}

=head1 AUTHOR

Inverse inc. <info@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005-2015 Inverse inc.

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

__PACKAGE__->meta->make_immutable;

1;
