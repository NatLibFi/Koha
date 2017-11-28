#!/usr/bin/env perl
#
# Copyright University of Helsinki 2017
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Dancer;
use Dancer::Config;
use Catmandu;
use Dancer::Plugin::Catmandu::SRU;
use Koha::Config;

my $kohaConfig = Koha::Config->read_from_file( Koha::Config->guess_koha_conf() );
die('Elasticsearch index_name missing from Koha config') unless $kohaConfig->{config}{elasticsearch}{index_name};

Catmandu->load( setting('confdir') );
my $catmanduConfig = Catmandu->config;
$catmanduConfig->{store}{sru}{options}{index_name} = $kohaConfig->{config}{elasticsearch}{index_name} . '_biblios';

my $options = {};
sru_provider '/sru', %$options;

dance;
