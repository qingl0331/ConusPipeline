#!/usr/bin/perl
use strict;
use warnings;
use Tie::IxHash;
use Bio::DB::Fasta;
use Statistics::R;
use Getopt::Long;
use Array::Utils qw(:all);
# coded by Qing Li on 07/29/16.
#Copyright (c) 2016 yandell lab. All rights reserved.


#-----------------------------------------------------------------------------
#----------------------------------- MAIN ------------------------------------
#-----------------------------------------------------------------------------

my $usage = "discoveryPipeline.pl [-option]  <configure file>\n
option:--hmm hmmModelPath

Description:
input xx.no_anot.??.fa should be the output of different species(sp and frame should be labeled in the id) from previous conotoxin annotation pipeline - xx.tri.no_anot.fa should have tpm value on the header.
conotoxinseq and noConotoxinseq are peptide seq in one-line header, one-line body format, not required to be output from previous conotoxin mining pipeline..
#1. for no.anot.pep.fa, extract seq from M to stop codon which are longer than 50 aas but shorter than 200 aas-switched to user input upper limit, with a regex pattern(2-14cysteine after 15-25aa from the beginning).remove the redundant seq(only keep the longest),since signalp can only start to predict from the 1st M, so have to trim the seq according to different Ms. for the trimmed ones,filtering by requiring length(50-200aa),2-14Cys from the beginning(trim and trmove the noanot.nt.fa accordingly). Then run signalP( -f short) on pepseq to get output, parse output(D-value use default-0.45,9th column==Y) to extract potential new superfamilies from non-annotated peptide,remove redundant ones(only keep the longest), get the D-value and cys%, put into hash --->noanot.cono.pep.rsem.fa, noanot.cono.nt.rsem.fa; 
#2.run hmm through noanot.cono.pep.fa to get more hits to annotate conotoxins, remove these hits from noanot.cono.pep.fa.
#3. use logistic regression - conotoxin/noCono as outcome, signalp D-value and Pcys and seq length as independent predictors,add a tab in the header of the potential conotoxin to label the predicted probability of being a conotoxin, label the predicted prob and tpm value on both nt and pep seq.  
#4. detail steps for logistic regression: run signalp on input conotoxinseq and noConotoxinseq, get their D-value; parse their seq to get cysteine percent, get their length; 
#5. use blastp on the filterProbTpm.noTox.pep.fa after filter on: abundant (> 100 tpm), high prob (> 0.6 probability) peptides, putative conotoxins of new superfamily will be reported only when there are 2 or more species in one hit each other.
#6. use tblastn to fish out other molluscan seq (like hormones)from the remaining 6 frame translated peptide which has no it in probability prediction nor hit in blastp.The database used are ncbi molluscan ntseq.  
#Note: remember to remove stop codon from newly blastx generated conotoxins in pep before cat the conotoxins into training dataset\n";
my$hmm;
GetOptions('hmm=s'=> \$hmm);
my $configFile=$ARGV[0];
my($triNoAnotFa,$triNoAnotPepFa,$conoSeq,$NoconoSeq,$tpmCutoff,$probCutoff,$evalCutoff,$DvalCutoff,$mn,$lengthCutoff,$sample);
open FH,$configFile;
while(defined (my$line=<FH>)){
	chomp ($line);	
	my@input=split /:/,$line;
	if ($input[0] eq "NoAnotNtFa"){
	 	$triNoAnotFa=$input[1];
	}elsif($input[0] eq "NoAnotPepFa"){
		$triNoAnotPepFa=$input[1];
	}elsif($input[0] eq "conoSeq"){
		$conoSeq=$input[1];
	}elsif($input[0] eq "NoconoSeq"){
		$NoconoSeq=$input[1];
	}elsif($input[0] eq "tpmCutoff"){
		$tpmCutoff=$input[1];
	
	}elsif($input[0] eq "probCutoff"){
		$probCutoff=$input[1];
	
	}elsif($input[0] eq "evalCutoff"){
		$evalCutoff=$input[1];
	}elsif($input[0] eq "DvalCutoff"){
		$DvalCutoff=$input[1];
	}elsif($input[0] eq "lengthCutoff"){
		$lengthCutoff=$input[1];
	}elsif($input[0] eq "molluscaNtDb"){
		$mn=$input[1];
	}elsif($input[0] eq "outputName"){
		$sample=$input[1];
	}
}
close FH;
die $usage unless $configFile;
die "please give noAnotNt file!" unless $triNoAnotFa;
die "please give noAnotPep file!" unless $triNoAnotPepFa;
die "please give conotoxin seq file!" unless $conoSeq;
die "please give nonconotoxin seq file!" unless $NoconoSeq;
die "please give tpmCutoff!" unless $tpmCutoff;
die "please give probability Cutoff!" unless $probCutoff;
die "please give evalue Cutoff!" unless $evalCutoff;
die "please give Dvalue Cutoff!" unless $DvalCutoff;
die "please give sequence length upper limit Cutoff!" unless $lengthCutoff;
die "please give molluscaNtDb!" unless $mn;
die "please give output name!" unless $sample;

my%tpmL;#{id}->[tpm,len], only annotated conotoxin is tpm ahead of len 
open FH,$triNoAnotFa; 
while(defined (my$line=<FH>)){
	if($line=~ />/){
		chomp ($line);
        	#my@t=split /\t/,$line;
        	my@t=split /\s+/,$line;
		$t[0]=~ s/>//;
		$t[2]=~ s/tpm://;
		$t[1]=~ s/len://;
        	$tpmL{$t[0]}=[$t[2],$t[1]];
	}
}
close FH;
#extract seq from M to stop codon which is longer than 50 aas but shorter than seqlength upper limit  with a regex pattern(2-14cysteine after 15-25aa from the beginning)
open FH1,$triNoAnotPepFa;
my($pepId,%pepSeq);
while (defined (my$line1=<FH1>)){
	chomp $line1;
        if($line1=~ /^>/){
		($pepId)=$line1=~ />(\S+)/;
	}else{
		my $mIndex=index($line1,'M');
		next if $mIndex==-1;
		my$pepLen=length $line1;
		my$checkLen=$pepLen-$mIndex;
		next unless($checkLen > 50 && $checkLen < $lengthCutoff);
		my($matureTox)=$line1=~ /^[A-Z]*M[A-Z]{14,24}(\S+)/;			
		next unless $matureTox;
		my@cys=$matureTox=~ /(C)/g;
		next unless (scalar @cys >=2 && scalar @cys <=14);
		$pepSeq{$line1}=$pepId;

	}	
}
close FH1;
#remove the redundant seq(only keep the longest)
my@pepSeq= keys %pepSeq;
my$uniqSeq=removeRedundant(\@pepSeq);
#use tblastn to fish out other molluscan seq (like hormones)from the remaining 6 frame translated peptide which has no it in probability prediction nor hit in blastp.The database used are ncbi molluscan nt and protein seq respectively. 
open OUT,">$sample.tri.no_anot.pep.clean.fa";
foreach my$uSeq(@$uniqSeq){
	print OUT ">$pepSeq{$uSeq}\n$uSeq\n";	
}
close OUT;
system("tblastn -db $mn -query $sample.tri.no_anot.pep.clean.fa -num_threads 20 -outfmt '6 std qframe sframe' -evalue $evalCutoff -matrix BLOSUM62 -max_target_seqs 1 -out $sample.vs.mn.tbn.out");
my($mtbnOut)=<$sample.vs.mn.tbn.out>;
my($cleanFa)=<$sample.tri.no_anot.pep.clean.fa>;
my$cleanDb=Bio::DB::Fasta->new($cleanFa);
my$nAPDb=Bio::DB::Fasta->new($triNoAnotPepFa);
my$db=Bio::DB::Fasta->new($triNoAnotFa);
my$mtbnHash=getHit($mtbnOut);
open OUT2,">$sample.mtbn.pep.fa";
open OUT3,">$sample.mtbn.nt.fa";
foreach my$mId(keys %{$mtbnHash}){
	#$mId=$sigPNumId{$mId} if $mId=~ /^[0-9]*$/gm;
	my($dbNId)=$mId=~ /(\S+)_frame\S+/;
	my($dbPId)=$mId;
        my$header=">$mId\tmolluscanHit:$mtbnHash->{$mId}\ttpm:$tpmL{$dbNId}->[0]\tlen:$tpmL{$dbNId}->[1]\n";
        my$ntSeq=$db-> get_Seq_by_id($dbNId);
	my $ntSeqstr  = $ntSeq-> seq;
        my$pepSeq=$nAPDb-> get_Seq_by_id($dbPId);
	my $pepSeqstr  = $pepSeq-> seq;
	my ($frame_strand) =$mId=~ /frame_(\S+)_/;
	my($frame)  = $frame_strand =~ /(\d+)/;
        my($strand) = $frame_strand =~ /([\+\-])/;
        $strand ||= '+';
	my$bSigPSeq=$cleanDb-> get_Seq_by_id($mId);
	my $bSigPSeqstr  = $bSigPSeq-> seq;
	my $mIndex=index($pepSeqstr,$bSigPSeqstr);
        my$pepLen=length($bSigPSeqstr);
	my $ntStart=$mIndex*3+$frame-1;
	my $ntLen=$pepLen*3;
	$ntSeqstr= revcom($ntSeqstr) if $strand eq '-';  
	my $ntOrf=substr $ntSeqstr, $ntStart, $ntLen;
        print OUT3 "$header$ntOrf\n";
        print OUT2 "$header$bSigPSeqstr\n";
}
close OUT2;
close OUT3;

my %sigPNumId; #{numId}->seqId with trimming info
my$idCount=1;
open OUT8,">$sample.tri.no_anot.pep.potentialNewToxBeforeSigP.fa";
foreach my$uSeq(@$uniqSeq){
	next if defined $mtbnHash->{$pepSeq{$uSeq}};
	my$offset=0;
	my$mIndex=index($uSeq,'M',$offset);	
	my$count=0;
	while($mIndex !=-1){
		my$uSeqM=substr $uSeq,$mIndex;	
		my$checkLen=length $uSeqM;
		last unless $checkLen > 50 && $checkLen <$lengthCutoff;
		my($matureTox)=$uSeqM=~ /^M[A-Z]{14,24}(\S+)/;                    
		last unless $matureTox;
		my$idLen=length("$pepSeq{$uSeq}.trim$count");
		if($idLen<55){
			print OUT8 ">$pepSeq{$uSeq}.trim$count\n$uSeqM\n";
		}else{
			print OUT8 ">$idCount\n$uSeqM\n";
			$sigPNumId{$idCount}="$pepSeq{$uSeq}.trim$count";
		}
		$offset=$mIndex+1;
		$count++;
		$idCount++;
		$mIndex=index($uSeq,'M',$offset);
	}
}
close OUT8;

#run signalp
system("signalp -t euk -f short  $sample.tri.no_anot.pep.potentialNewToxBeforeSigP.fa > $sample.sigP.short_out");
#parse signalp output
my%sigPSeq;
my($beforeSigPFa)=<$sample.tri.no_anot.pep.potentialNewToxBeforeSigP.fa>;
my$SigPDb=Bio::DB::Fasta->new($beforeSigPFa);
open OUT9,">$sample.tri.no_anot.pep.potentialNewToxAfterSigP.fa";
open OUT13,">$sample.tri.no_anot.nt.potentialNewToxAfterSigP.fa";
my%sigDVal;
open(FH2, "$sample.sigP.short_out")or die "Can't open $sample.sigP.short_out for reading: $!\n";
while(defined(my$line=<FH2>)){
	next if $line=~ /^#/;
	my@p=split /\s+/,$line;
	next if $p[8] < $DvalCutoff;
	my$seq=$SigPDb-> get_Seq_by_id($p[0]);
        my $seqstr  = $seq-> seq;
	if(!defined $sigPNumId{$p[0]}){
		$sigPSeq{$seqstr}=$p[0];			
		$sigDVal{$p[0]}=$p[8];
	}else{
		$sigPSeq{$seqstr}=$sigPNumId{$p[0]};
		$sigDVal{$sigPNumId{$p[0]}}=$p[8];
	}
}
close FH2;
my(@testConoNocono,@testCysP,@testDVal,@testLen,%forNumId);#{numId}->seqId
my$numId=1;
my%sigPIdSeq;#{id}->[len,tpm,ntSeq,pepSeq]
my@sigPSeq=keys %sigPSeq;
my$uniqSigPSeq=removeRedundant(\@sigPSeq);
foreach my$uSigPSeq(@$uniqSigPSeq){
		my@cys=$uSigPSeq=~ /(C)/g;
		my$len=length($uSigPSeq);
		my$cysNum=scalar @cys;
		my$cysPct=$cysNum/$len;
		my($dbNId)=$sigPSeq{$uSigPSeq}=~ /(\S+)_frame\S+/;
		my($dbPId)=$sigPSeq{$uSigPSeq}=~ /(\S+)\.trim\S+/;
		my$ntSeq=$db-> get_Seq_by_id($dbNId);
		#print "$ntSeq\n";		
                my $ntSeqstr  = $ntSeq-> seq;
		my$pepSeq=$nAPDb-> get_Seq_by_id($dbPId);
                my $pepSeqstr  = $pepSeq-> seq;
		my ($frame_strand) = $sigPSeq{$uSigPSeq}=~ /frame_(\S+)_/;
                my($frame)  = $frame_strand =~ /(\d+)/;
                my($strand) = $frame_strand =~ /([\+\-])/;
                $strand ||= '+';
		my $mIndex=index($pepSeqstr,$uSigPSeq);
                my$pepLen=length($uSigPSeq);
		push @testLen, $pepLen;
                my $ntStart=$mIndex*3+$frame-1;
                my $ntLen=$pepLen*3;
		$ntSeqstr= revcom($ntSeqstr) if $strand eq '-';  
		my $ntOrf=substr $ntSeqstr, $ntStart, $ntLen;
		my$header="len:$tpmL{$dbNId}->[1]\ttpm:$tpmL{$dbNId}->[0]";
		print OUT9 ">$sigPSeq{$uSigPSeq}\t".$header."\n$uSigPSeq\n";	
		print OUT13 ">$sigPSeq{$uSigPSeq}\t".$header."\n$ntOrf\n";	
		$sigPIdSeq{$sigPSeq{$uSigPSeq}}=[$tpmL{$dbNId}->[1],$tpmL{$dbNId}->[0],$ntOrf,$uSigPSeq];
		push @testConoNocono,$numId;
		$forNumId{$numId}=$sigPSeq{$uSigPSeq};	
		push @testCysP,$cysPct;
		push @testDVal,$sigDVal{$sigPSeq{$uSigPSeq}}; 
		$numId++;
}
close OUT13;
close OUT9;
%sigDVal=();
#run hmm (if hmm option is turned on) through noanot.cono.pep.fa to get more hits to annotate conotoxins, remove these hits from noanot.cono.pep.fa.
my%hmmSupfam;
if($hmm){
	my@hmmNameFiles=<$hmm/*hmm>;
	foreach my $file(@hmmNameFiles){
		my($fileId)=$file=~ /supfam\.(\S+)\.hmm/;
		system("hmmsearch $file $sample.tri.no_anot.pep.potentialNewToxAfterSigP.fa > $fileId.out");
		open FH3,"$fileId.out"|| die"can't open $fileId.out\n";
		while(defined(my$line=<FH3>)){
			last if $line=~ /Domain/;
			if ($line=~ /frame/){
				chomp ($line);
				my@h= split /\s+/,$line;
				if(!defined $hmmSupfam{$h[9]}||$hmmSupfam{$h[9]}{score}<$h[2]){
					$hmmSupfam{$h[9]}{score}=$h[2];		
					$hmmSupfam{$h[9]}{supfam}=$fileId;		
				}
			}
		}		
		close FH3
	}


	open OUT10,">$sample.tri.no_anot.noHmm.pep.potentialNewToxAfterSigP.fa";
	open OUT11,">$sample.tri.no_anot.Hmm.pep.potentialNewToxAfterSigP.fa";
	open OUT12,">$sample.tri.no_anot.Hmm.nt.potentialNewToxAfterSigP.fa";
	my@hIds=sort{$sigPIdSeq{$b}->[1]<=>$sigPIdSeq{$a}->[1]} keys(%sigPIdSeq);
	foreach my$id(@hIds){
		if(defined $hmmSupfam{$id}){
			my $header=">$id\tHmmSupFam:$hmmSupfam{$id}{supfam}\ttpm:$sigPIdSeq{$id}->[1]\tlen:$sigPIdSeq{$id}->[0]\n";
			print OUT11 $header.$sigPIdSeq{$id}->[3]."\n";
			print OUT12 $header.$sigPIdSeq{$id}->[2]."\n";
		}
	}
	close OUT10;
	close OUT11;
	close OUT12;
}	
# use logistic regression - conotoxin/noCono as outcome, signalp D-value and Pcys as independent predictors,add a tab in the header of the potential conotoxin to label the predicted probability of being a conotoxin, label the predicted prob and tpm value on both nt and pep seq. 


#run signalp on input conotoxinseq and noConotoxinseq, get their D-value, if no signalp hits then give 0 to the D-val.
system("signalp -t euk -f short  $conoSeq > $sample.conoSeq.sigP.short_out");
system("signalp -t euk -f short  $NoconoSeq > $sample.NoconoSeq.sigP.short_out");
my($conoSigpOut)=<$sample.conoSeq.sigP.short_out>;
my($NoconoSigpOut)=<$sample.NoconoSeq.sigP.short_out>;
my$conoHash=getCysDL($conoSeq,$conoSigpOut);#{id}->[cys%, D-val,len]
my$NoconoHash=getCysDL($NoconoSeq,$NoconoSigpOut);
my@conoHK=keys %{$conoHash};
my@NoconoHK=keys %{$NoconoHash};
my@conoNocono=(1) x @conoHK;
my@Nocono=(0) x @NoconoHK;
push (@conoNocono,@Nocono);
#my$total=@conoNocono;#debugg
#print "total:$total\n";#debugg
my(@cysP,@DVal,@len);
foreach my $id(keys%{$conoHash}){
	push @cysP,$conoHash->{$id}->[0];
	push @DVal,$conoHash->{$id}->[1];
	push @len,$conoHash->{$id}->[2];
}
foreach my $id(keys%{$NoconoHash}){
	push @cysP,$NoconoHash->{$id}->[0];
	push @DVal,$NoconoHash->{$id}->[1];
	push @len,$NoconoHash->{$id}->[2];
}
#use logistic regression - conotoxin/noCono as outcome, signalp D-value and Pcys as independent predictors,

open OUT1,">$sample.R";
print OUT1 'library(ggplot2)'."\n";
print OUT1 'library(Rcpp)'."\n";
print OUT1 'library(aod)'."\n";
print OUT1 'conoNocono=c('.join(',',@conoNocono).')'."\n";
print OUT1 'DVal=c('.join(',',@DVal).')'."\n";
print OUT1 'cysP=c('.join(',',@cysP).')'."\n";
print OUT1 'len=c('.join(',',@len).')'."\n";
print OUT1 'mydataMatri=cbind(conoNocono,cysP,DVal,len)'."\n";
print OUT1 'mydata=as.data.frame(mydataMatri)'."\n";
print OUT1 'mylogit <- glm(conoNocono ~ cysP + DVal + len, data = mydata, family = "binomial")'."\n";
print OUT1 'modelFitPVal=with(mylogit, pchisq(null.deviance - deviance, df.null - df.residual, lower.tail = FALSE))'."\n";
print OUT1 'write.table(modelFitPVal,file="./'."$sample.modelFitPVal".'.txt",sep="\t")'."\n";
print OUT1 'sum=summary(mylogit)'."\n";
print OUT1 'capture.output(sum,file="./'."$sample.modelSum".'.txt")'."\n";
print OUT1 'conoNocono=c('.join(',',@testConoNocono).')'."\n";
print OUT1 'DVal=c('.join(',',@testDVal).')'."\n";
print OUT1 'cysP=c('.join(',',@testCysP).')'."\n";
print OUT1 'len=c('.join(',',@testLen).')'."\n";
print OUT1 'newdata1Matri=cbind(conoNocono,cysP,DVal,len)'."\n";
print OUT1 'newdata1=as.data.frame(newdata1Matri)'."\n";
print OUT1 'newdata2=cbind(newdata1, predict(mylogit, newdata = newdata1, type="link", se=TRUE))'."\n";
print OUT1 'newdata2=within(newdata2, {PredictedProb <- plogis(fit)'."\n".'LL <- plogis(fit - (1.96 * se.fit))'."\n".'UL <- plogis(fit + (1.96 * se.fit))'."\n".'})'."\n";
print OUT1 'oridata=cbind(mydata, predict(mylogit, newdata = mydata, type="link", se=TRUE))'."\n";
print OUT1 'oridata=within(oridata, {PredictedProb <- plogis(fit)'."\n".'LL <- plogis(fit - (1.96 * se.fit))'."\n".'UL <- plogis(fit + (1.96 * se.fit))'."\n".'})'."\n";
print OUT1 'write.table(newdata2,file="./'."$sample.numId.logitSample".'.txt",sep="\t")'."\n";
print OUT1 'write.table(oridata,file="./'."$sample.logitRef".'.txt",sep="\t")'."\n";
close OUT1;
my $R=Statistics::R->new();
$R->run_from_file("$sample.R");
#parse $sample.numId.logitSample.txt file and make a new hash- {the value of %forNumId(original seq ID)} ->  predicted probability. $sample.logitRef.txt and $sample.modelFitPVal.txt are for checking the model -whether it fits or not
open FH,"$sample.numId.logitSample.txt"; 
open OUT,">$sample.seqId.logitSample.txt"; 
open OUT2,">$sample.filterProbTpm.pep.fa"; 
open OUT1,">$sample.filterProbTpm.nt.fa"; 
open OUT3,">$sample.filterProbTpm.noTox.pep.fa"; 
my@noProbId;
while(defined(my$line=<FH>)){
	next if $line=~ /conoNocono/;
	my@prob=split /\t/,$line;
	my$seqId=$forNumId{$prob[1]};
	#$forSeqId{$seqId}=$prob[10];
	$line=~ s/$prob[1]/$seqId/;
	print OUT $line;
# filter on: abundant (> ?? tpm), high prob (> 0.6 probability) peptides; for tpm,nt&pep seq: $sigPIdSeq{$seqId}->[len,tpm,ntSeq,pepSeq] 
	if(($prob[10]>=$probCutoff) && (!defined $hmmSupfam{$seqId}) && ($sigPIdSeq{$seqId}->[1] >= $tpmCutoff)){
		my$ntSeq=$sigPIdSeq{$seqId}->[2];
		my$pepSeq=$sigPIdSeq{$seqId}->[3];
		my$sFam=substr $pepSeq,0,5;
		my $header=">$seqId\tsupFam:putative $sFam\ttpm:$sigPIdSeq{$seqId}->[1]\tlen:$sigPIdSeq{$seqId}->[0]\tprobability:$prob[10]";
		print OUT1 "$header$ntSeq\n"; 
		print OUT2 "$header$pepSeq\n"; 
	}elsif(($prob[10]<$probCutoff) && (!defined $hmmSupfam{$seqId}) && ($sigPIdSeq{$seqId}->[1] >= $tpmCutoff)){
		my$pepSeq2=$sigPIdSeq{$seqId}->[3];
		my $header2=">$seqId\ttpm:$sigPIdSeq{$seqId}->[1]\tlen:$sigPIdSeq{$seqId}->[0]\n";
		push @noProbId,$seqId;
		print OUT3 "$header2$pepSeq2\n";
	}
}
close FH;
close OUT;
close OUT1;
close OUT2;
close OUT3;

#use blastp on the filterProbTpm.noTox.pep.fa after filter on: abundant (> 100 tpm), high prob (> 0.6 probability) peptides, putative conotoxins of new superfamily will be reported only when there are 2 or more species in one hit each other.
system("makeblastdb -in $sample.filterProbTpm.noTox.pep.fa -out $sample.noTox_protein -dbtype prot");
system("blastp -db $sample.noTox_protein -query $sample.filterProbTpm.noTox.pep.fa -num_threads 20 -outfmt '6 std qframe sframe' -evalue $evalCutoff -out $sample.bp.out");
my%uniqBpId;
open OUT2, ">$sample.bp.putative.newSupfam.tox.nt.fa";
open OUT3, ">$sample.bp.putative.newSupfam.tox.pep.fa";
open FH, "$sample.bp.out";
while(defined(my$line=<FH>)){
        my@bp=split /\t/,$line;
        my($sp1)=$bp[0]=~ /(\S+)\.TR/;
        my($sp2)=$bp[1]=~ /(\S+)\.TR/;
        $sp1=cleanSpName($sp1);
        $sp2=cleanSpName($sp2);
        if(($sp1 ne $sp2)&&(!defined $uniqBpId{$bp[0]})){
                $uniqBpId{$bp[0]}=1;
                my$ntSeq1=$sigPIdSeq{$bp[0]}->[2];
                my$pepSeq1=$sigPIdSeq{$bp[0]}->[3];
                my$sFam=substr $pepSeq1,0,5;
                my$header1=">$bp[0]\tsupFam:putative $sFam\ttpm:$sigPIdSeq{$bp[0]}->[1]\tlen:$sigPIdSeq{$bp[0]}->[0]\n";
                print OUT2 "$header1$ntSeq1\n";
                print OUT3 "$header1$pepSeq1\n";
        }
}
close FH;
close OUT2;
close OUT3;
system("cat $sample.filterProbTpm.pep.fa $sample.mtbn.pep.fa $sample.bp.putative.newSupfam.tox.pep.fa > $sample.potential.newSupfam.pep.fa");
system("cat $sample.filterProbTpm.nt.fa $sample.mtbn.nt.fa $sample.bp.putative.newSupfam.tox.nt.fa > $sample.potential.newSupfam.nt.fa");
#-----------------------------------------------------------------------------
#-----------------------------------------------------------------------------
#---------------------------------- SUBS -------------------------------------
sub getHit{
	my $blast_file = shift;
	open FH1,$blast_file;
	my %toxin;
	while (<FH1>) {
		my @i = split /\t/, $_;
		if (not defined $toxin{$i[0]}) {
			$toxin{$i[0]} = $i[1];
		}
	}
	return (\%toxin);	

}
sub cleanSpName{
        my$sp=shift;
        $sp=~ s/SG//;
        $sp=~ s/VD//;
        $sp=~ s/NR//;
        $sp=~ s/4section//;
        return $sp;
}


sub getCysDL{
	my$seq=shift;
	my$sigpOut=shift;
	my$sigDVal=getDVal($sigpOut);
	open FH,$seq;
	my($id,%cysD);#%cysD:{id}->[cys%, D-val,len]
	while(defined(my$line=<FH>)){
		chomp $line;
		if($line=~ />/){
			($id)=$line=~ />(\S+)/;

		}else{
			my@cys=$line=~ /(C)/g;
                	my$len=length($line);
                	my$cysNum=scalar @cys;
                	my$cysPct=$cysNum/$len;	
			if($sigDVal->{$id}){
				$cysD{$id}=[$cysPct,$sigDVal->{$id},$len];
			}else{
				$cysD{$id}=[$cysPct,0,$len];
			}
		}	


	}
	
	return \%cysD;
	close FH;
}

sub getDVal{
	my $sigpOut=shift;
	my%sigDVal;
	open(FH2, $sigpOut)or die "Can't open $sigpOut for reading: $!\n";
	while(defined(my$line=<FH2>)){
		next if $line=~ /^#/;
		my@p=split /\s+/,$line;
		$sigDVal{$p[0]}=$p[8]; 
	}
	return \%sigDVal;
	close FH2;
}
sub calculateN50{
	my$sample=shift;
	my($filename)=<$sample.trinity.Trinity.fasta>;
	die "trinity file does not exist!" unless -r $filename;
	my $n;
my ($len, $total)=(0,0);
my @x;
open FH, $filename;
while (<FH>){
        if(/>/){
                if($len>0){
                        $total+=$len;
                        push @x,$len;
                 }
        $len=0;
        }else{
              s/\s//g;
              $len+=length($_);
        }
}
close FH;
#take care of the last seq
if ($len>0){
        $total+=$len;
        push @x,$len;
}
@x=sort{$b<=>$a} @x;
my ($count,$half,$N50)=(0,0);
for (my $j=0;$j<@x;$j++){
        $count+=$x[$j];
        if (($count>=$total/2)&&($half==0)){
                $n=@x;
                $N50=$x[$j];
                $half=$x[$j];
                last;
        }
}
return ($N50,$total,$n);
}
sub removeRedundant{
	my$pepSeq=shift;
	my@sorted=sort {length $b <=> length $a} @$pepSeq;
	my@uniqSeq;
	my$flag=0;
	foreach my $seq(@sorted){
		my$seqBL=uc($seq);
        	$flag=0;
        	foreach my$uSeq(@uniqSeq){
			my$uSeqBL=uc($uSeq);
                	if($uSeqBL=~ /$seqBL/){
                        	$flag=1;
                	}
        	}
        	if($flag==0){
                	push @uniqSeq,$seq;
        	}

	}
	return \@uniqSeq;
}






sub translate_print_seq {
        my $entry=shift;
        my $seq=shift;
        my $frame=shift;
	my $fh=shift;
	my $pep_RL=shift;
        my $pep = translate_with_frame($seq, $frame);
        my $rpep = translate_with_frame($seq, -$frame);
	#print $fh $entry."_frame_$frame\n$pep\n";
	#print $fh $entry."_frame_-$frame\n$rpep\n";

        my @peps=$pep=~ /([A-Z]{$pep_RL,})\*/g;
                for (my$i=0;$i<@peps;$i++){
                        print $fh ">$entry"."_frame_$frame"."_$i\n$peps[$i]\n";
                }

        my @rpeps=$rpep=~ /([A-Z]{$pep_RL,})\*/g;
                for (my$k=0;$k<@rpeps;$k++){
                        print $fh ">$entry"."_frame_-$frame"."_$k\n$rpeps[$k]\n";
                }

}


sub get_anot {
        my $header=shift;
        my $annotation;
        my @annot=split(/\t/,$header);
        my @note=split(/:/,$annot[1]);
        if ($note[1]=~ /OS=/){
                my @swp=split(/OS=/,$note[1]);
                $annotation=$swp[0];
        }else{
                $annotation=$note[1];
        }
        return $annotation;
}



sub get_nt {
	my$anot_fa_file=shift;
 	open(FH1,$anot_fa_file);
	open(OUT1,">$anot_fa_file.nt");
	while(defined(my$line1=<FH1>)){
        	if($line1=~ />/){
                	print OUT1 $line1;	
			my$line2=<FH1>;
			$line2=~ s/^nucleotide://;
			print OUT1 $line2;
		}
	}
	close OUT1;
	close FH1;

 }


sub select_reads{
	my $id=shift;
	my $id_dir=shift;
	my $conca_reads=shift;
	system("xargs samtools faidx $conca_reads < $id_dir/$id > $id_dir/$id.fa");
}
sub deconcatenate_reads{
	my $id=shift;
        my $id_dir=shift;
	open FH, "$id_dir/$id.fa";
        open OUT1,">$id_dir/$id.1.fa";
        open OUT2,">$id_dir/$id.2.fa";
        open OUT3,">$id_dir/$id.s.fa";
	my($readFa)=<$id_dir/$id.fa>;
	my$db=Bio::DB::Fasta->new($readFa);
        my$rid;
	my$singletons=0;
        while(my$line=<FH>){
                chomp $line;
                if($line=~ />/){
                        ($rid)=$line=~ />(\S+)/;
			my$seq=$db-> get_Seq_by_id($rid);
                	my $seqstr  = $seq-> seq;
               		my$separator_indx=index($seqstr,'-');
			if($separator_indx==-1){
				print OUT3 ">$rid\n$seqstr\n";
				$singletons++;
			}else{	
				my$length=$separator_indx-1;	
				my$offset=$separator_indx+1;
 				my$read1=substr($seqstr,0,$length);
 				my$read2=substr($seqstr,$offset);
                        	print OUT1 ">$rid/1\n$read1\n";
                        	print OUT2 ">$rid/2\n$read2\n";
			}
                } 
        }
	close(FH);
	close(OUT1);
	close(OUT2);
	close(OUT3);
	system("rm $id_dir/$id.s.fa") if $singletons==0;
}

sub trinity_assembly{
	my $id=shift;
        my $id_dir=shift;
	system("Trinity --seqType fa --max_memory 30G --bypass_java_version_check --left $id_dir/$id".".1.fa --right $id_dir/$id".".2.fa --CPU 6 --bflyHeapSpaceMax 5G --bflyCPU 2 --KMER_SIZE 31 --SS_lib_type RF --min_kmer_cov 10 --min_glue 10 --min_contig_length 180 --output $id_dir/trin/$id.trinity --full_cleanup");
}
sub blastx{
	my $id=shift;
        my $id_dir=shift;
	my $bx_db=shift;
	system("blastx -db $bx_db -query $id_dir/trin/$id.trinity.Trinity.fasta -num_threads 1 -outfmt '6 std qframe sframe' -evalue 1e-4 -word_size 3 -matrix BLOSUM62 -gapopen 11 -gapextend 1 -comp_based_stats t -seg no -soft_masking true -out $id_dir/trin/$id.bx.out");
}
sub annotation{
my $id=shift;
my $blast_file = "$id.bx.out";
my $t_file = "$id.tri.nt.filtered.rsem.fa";
my $e_thres = 1e-5;

open FH1,$blast_file;
my %toxin;
my %first;
while (<FH1>) {
        my @i = split /\t/, $_;

        if (not defined $toxin{$i[0]}{hit}) {
                $toxin{$i[0]}->{hit} = $i[1];
                $toxin{$i[0]}->{frame} = $i[12];
                $toxin{$i[0]}->{e} = $i[10];
        }

        $first{$i[0]} = $i[1] if not defined $first{$i[0]};
        if ($i[1] eq $first{$i[0]} or $i[10] <= $e_thres) {
                push @{$toxin{$i[0]}{al}}, [$i[6], $i[7]];
        }
}
close(FH1);

my %fa;
open FH, $t_file;
my $entry;
my @id_order;
my $order=1;
while (<FH>) {
        if (/^>(\S+)/) {
                $entry = $1;
	#debug#	print STDERR "$entry\n";
		push(@id_order, $entry);
        } else {
                chomp;
                $fa{$entry} .= $_;
        }
}
close FH;
my%nPHeaderSeq;
#tie %pepSeq,"Tie::IxHash";
foreach my $tid (@id_order) {
     if(defined $toxin{$tid}){

        $toxin{$tid}->{seq} = $fa{$tid};
        my $length = length $fa{$tid};
        my $peptide = translate_with_frame($toxin{$tid}->{seq}, $toxin{$tid}->{frame});
        $peptide = lc $peptide;
        foreach my $al (@{$toxin{$tid}{al}}) {
                my ($l, $r) = @$al;
                ($l, $r) = ($r,$l) if $l > $r;

                if ($toxin{$tid}{frame} <0) {
                        ($l, $r) = ($length -$r +1, $length - $l + 1);
                }

                my $frame_off = abs($toxin{$tid}->{frame})-1;
                $l = int(($l - $frame_off)/3) +1;
                $r = int(($r - $frame_off)/3 -1)+1;

                $l = 1 if($l < 1);

                my $substr = substr $peptide, $l-1, $r-$l+1;
                $substr = uc $substr;
                substr $peptide, $l-1, $r-$l+1, $substr;
        }

        $/="\n";
	$nPHeaderSeq{$tid}=[$toxin{$tid}{hit},$toxin{$tid}{frame},$toxin{$tid}{seq},$peptide];
     }else{
        $nPHeaderSeq{$tid}=[$fa{$tid}];
    }
}
return \%nPHeaderSeq;
}
#----------------------------------------------------------------------------------------------------------------------------
sub translate_codon {
        my $c = shift;

        $c = uc($c);
        $c =~ s/U/T/g;

        return 'A' if $c eq 'GCT'||$c eq 'GCC'||$c eq 'GCA'||$c eq 'GCG';
        return 'R' if $c eq 'CGT'||$c eq 'CGC'||$c eq 'CGA'||$c eq 'CGG'||$c eq 'AGA'
                ||    $c eq 'AGG';
        return 'N' if $c eq 'AAT'||$c eq 'AAC';
        return 'D' if $c eq 'GAT'||$c eq 'GAC';
        return 'C' if $c eq 'TGT'||$c eq 'TGC';
        return 'Q' if $c eq 'CAA'||$c eq 'CAG';
        return 'E' if $c eq 'GAA'||$c eq 'GAG';
        return 'G' if $c eq 'GGT'||$c eq 'GGC'||$c eq 'GGA'||$c eq 'GGG';
        return 'H' if $c eq 'CAT'||$c eq 'CAC';
        return 'I' if $c eq 'ATT'||$c eq 'ATC'||$c eq 'ATA';
        return 'L' if $c eq 'TTA'||$c eq 'TTG'||$c eq 'CTC'||$c eq 'CTA'||$c eq 'CTG'
                ||    $c eq 'CTT';
        return 'K' if $c eq 'AAA'||$c eq 'AAG';
        return 'M' if $c eq 'ATG';
        return 'F' if $c eq 'TTT'||$c eq 'TTC';
        return 'P' if $c eq 'CCT'||$c eq 'CCC'||$c eq 'CCA'||$c eq 'CCG';
        return 'S' if $c eq 'TCT'||$c eq 'TCC'||$c eq 'TCA'||$c eq 'TCG'||$c eq 'AGT'
                ||    $c eq 'AGC';
        return 'T' if $c eq 'ACT'||$c eq 'ACC'||$c eq 'ACA'||$c eq 'ACG';
        return 'W' if $c eq 'TGG';
        return 'Y' if $c eq 'TAT'||$c eq 'TAC';
        return 'V' if $c eq 'GTT'||$c eq 'GTC'||$c eq 'GTA'||$c eq 'GTG';

        return '*' if $c eq 'TAA'||$c eq 'TGA'||$c eq 'TAG';  # * stands for stop codon.
        return 'O'; # O stands for unknown codon;
}

sub revcom {
        my $seq = shift;

        my @seq = split //, $seq;

        my $revcom_seq = '';
        for (my $i = $#seq; $i >=0; $i--) {
                my $character = $seq[$i];
                $character = 'T' if $character eq 'U';
                $character = 't' if $character eq 'u';

                if ($character eq 'A') {
                        $revcom_seq .= 'T';
                }
                elsif ($character eq 'G') {
                        $revcom_seq .= 'C';
                }
                elsif ($character eq 'C') {
                        $revcom_seq .= 'G';
                }
                elsif ($character eq 'T') {
                        $revcom_seq .= 'A';
                }
                elsif ($character eq 'a') {
                        $revcom_seq .= 't';
                }
                elsif ($character eq 't') {
                        $revcom_seq .= 'a';
                }
                elsif ($character eq 'g') {
                        $revcom_seq .= 'c';
                }
                elsif ($character eq 'c') {
                        $revcom_seq .= 'g';
                }
                elsif ($character eq 'N') {
                        $revcom_seq .= 'N';
                }
                elsif ($character eq 'n') {
                        $revcom_seq .= 'n';
                }
        }
        return $revcom_seq;
}

sub translate_with_frame {
        my $seq = shift;
        my $strand_frame = shift;
	 # Change 9/11/14 to fix strand/frame parsing
	 # my ($strand, $frame) = split //, $strand_frame;
        my ($frame)  = $strand_frame =~ /(\d+)/;
        my ($strand) = $strand_frame =~ /([\+\-])/;
        $strand ||= '+';

        $seq = revcom($seq) if $strand eq '-';
        my @seq = split //, $seq;

        my $peptide = '';
        for (my $i= $frame-1; $i <= $#seq -2; $i+=3) {
                my $codon = $seq[$i].$seq[$i+1].$seq[$i+2];
                my $aa = translate_codon($codon);
                $peptide .= $aa;
        }

        return $peptide;
}
