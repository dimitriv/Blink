/*
Copyright (c) Microsoft Corporation
All rights reserved.

Licensed under the Apache License, Version 2.0 (the ""License""); you
may not use this file except in compliance with the License. You may
obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

THIS CODE IS PROVIDED ON AN *AS IS* BASIS, WITHOUT WARRANTIES OR
CONDITIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT
LIMITATION ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR
A PARTICULAR PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.

See the Apache Version 2.0 License for specific language governing
permissions and limitations under the License.
*/
#ifdef BLADE_RF

#include <stdio.h>
#include <assert.h>

#include "bladerf_radio.h"
#include "params.h"
#include "numerics.h"


// Currently hardcoded, should be put in params
//#define BLADE_RF_RX_FREQ     2412000000
#define BLADE_RF_RX_LNA      BLADERF_LNA_GAIN_MAX
//#define BLADE_RF_RX_VGA1     20
#define BLADE_RF_RX_VGA2     BLADERF_RXVGA2_GAIN_MIN
#define BLADE_RF_RX_BUFF_L   8096

extern int stop_program; 

static struct bladerf_quick_tune fcenter, fside;

// Set params_tx == NULL or params_rx = NULL if unused
int BladeRF_RadioStart(BlinkParams *params_tx, BlinkParams *params_rx)
{
	int status;
	bladerf *dev;
	
	if (params_tx == NULL && params_rx == NULL) {
		printf("Both TX and RX are false, exiting...\n\n");
		return -1;
	}
	printf("Opening and initializing device...\n\n");


	status = bladerf_open(&dev, "");
	if (status != 0) {
		fprintf(stderr, "Failed to open device: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	assert(dev!=NULL);
	if (params_tx != NULL) {
		params_tx->radioParams.dev = dev;
		status = BladeRF_ConfigureTX(params_tx);
		if (status != 0) {
			fprintf(stderr, "Failed to configure TX: %s\n",
				bladerf_strerror(status));
			goto out;
		}
		else {
			printf("Configure TX done!\n\n");
		}
	}
	
	if (params_rx != NULL) {
		params_rx->radioParams.dev = dev;
		status = BladeRF_ConfigureRX(params_rx);
		if (status != 0) {
			fprintf(stderr, "Failed to configure RX: %s\n",
				bladerf_strerror(status));
			goto out;
		}
		else {
			printf("Configure RX done!\n\n");
		}
	}

	/*
	status = bladerf_calibrate_dc(params_tx->radioParams.dev, BLADERF_DC_CAL_LPF_TUNING);
	if (status != 0) {
		fprintf(stderr, "Failed to calibrate TX module: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	status = bladerf_calibrate_dc(params_tx->radioParams.dev, BLADERF_DC_CAL_TX_LPF);
	if (status != 0) {
		fprintf(stderr, "Failed to calibrate TX module: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	status = bladerf_calibrate_dc(params_tx->radioParams.dev, BLADERF_DC_CAL_RX_LPF);
	if (status != 0) {
		fprintf(stderr, "Failed to calibrate TX module: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	status = bladerf_calibrate_dc(params_tx->radioParams.dev, BLADERF_DC_CAL_RXVGA2);
	if (status != 0) {
		fprintf(stderr, "Failed to calibrate TX module: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	*/
	
	//bladerf_set_correction(params->radioParams.dev, module, BLADERF_CORR_LMS_DCOFF_I, params->radioParams.DCBias);
	//bladerf_set_correction(params->radioParams.dev, module, BLADERF_CORR_LMS_DCOFF_Q, params->radioParams.DCBias);
	
out:
	if (status != 0) {
		bladerf_close(dev);
		stop_program = true;
		return -1;
	}

	return 0;
}

int BladeRF_SwitchTXFrequency(bladerf *dev, bool center)
{
	int status = 0;
	if (true == center) {
		status = bladerf_schedule_retune(dev, BLADERF_MODULE_TX, BLADERF_RETUNE_NOW, 0, &fcenter);
	}
	else {
		status = bladerf_schedule_retune(dev, BLADERF_MODULE_TX, BLADERF_RETUNE_NOW, 0, &fside);
	}
	return status;
}
int  BladeRF_ConfigureTX(BlinkParams *params)
{
	int status;
	bladerf_module module = BLADERF_MODULE_TX;

	
	status = bladerf_set_tuning_mode(params->radioParams.dev, BLADERF_TUNING_MODE_FPGA);
	if (status != 0) {
		fprintf(stderr, "Failed to set FGPA tunning mode: %s\n",
			bladerf_strerror(status));
		goto out;
	}

	status = bladerf_set_frequency((params->radioParams.dev), module, params->radioParams.CentralFrequency - 50e6);
	if (status != 0) {
		fprintf(stderr, "Failed to set TX frequency: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("Second TX Frequency: %u Hz\n", params->radioParams.CentralFrequency);
	}

	status = bladerf_get_quick_tune((params->radioParams.dev), module, &fside);
	if (status != 0) {
		fprintf(stderr, "Failed to get quick tune: %s\n",
			bladerf_strerror(status));
		goto out;
	}


	status = bladerf_set_frequency((params->radioParams.dev), module, params->radioParams.CentralFrequency);
	if (status != 0) {
		fprintf(stderr, "Failed to set TX frequency: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("First TX Frequency: %u Hz\n", params->radioParams.CentralFrequency);
	}

	status = bladerf_get_quick_tune((params->radioParams.dev), module, &fcenter);
	if (status != 0) {
		fprintf(stderr, "Failed to get quick tune: %s\n",
			bladerf_strerror(status));
		goto out;
	}

	status = bladerf_set_sample_rate((params->radioParams.dev), module, params->radioParams.SampleRate, NULL);
	if (status != 0) {
		fprintf(stderr, "Failed to set TX sample rate: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("TX Samplerate: %u sps\n", params->radioParams.SampleRate);
	}

	status = bladerf_set_bandwidth((params->radioParams.dev), module,
		params->radioParams.Bandwidth, NULL);
	if (status != 0) {
		fprintf(stderr, "Failed to set TX bandwidth: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("TX Bandwidth: %u Hz\n", params->radioParams.Bandwidth);
	}


	status = bladerf_set_txvga1((params->radioParams.dev), params->radioParams.TXgain);
	if (status != 0) {
		fprintf(stderr, "Failed to set TX VGA1 gain: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("TX VGA1 gain: %d\n", params->radioParams.TXgain);
	}


	status = bladerf_set_txvga2((params->radioParams.dev), params->radioParams.TXgain);
	if (status != 0) {
		fprintf(stderr, "Failed to set TX VGA2 gain: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {	
		printf("TX VGA2 gain: %d\n", params->radioParams.TXgain);	
	}
	// TX buffer
	params->TXBuffer = malloc(params->radioParams.TXBufferSize);
	if (params->TXBuffer == NULL) {
		perror("malloc");
		exit(1);
	}

out:
	if (status != 0) {
		bladerf_close(params->radioParams.dev);
		stop_program = true;
		return -1;
	}


	// Just copied from an example
	// TBD: smart choice here?
	const unsigned int num_buffers = 16;
	const unsigned int buffer_size = 8192;  //
	const unsigned int num_transfers = 8;
	const unsigned int timeout_ms = 3500;

	// Configure both the device's RX and TX modules for use with the synchronous
	// interface. SC16 Q11 samples *without* metadata are used. 
	status = bladerf_sync_config(params->radioParams.dev,
		module,
		BLADERF_FORMAT_SC16_Q11,
		num_buffers,
		buffer_size,
		num_transfers,
		timeout_ms);

	if (status != 0) {
		fprintf(stderr, "Failed to configure TX sync interface: %s\n",
			bladerf_strerror(status));
		goto out1;
	}

	// We must always enable the modules *after* calling bladerf_sync_config(),
	// and *before* attempting to RX or TX samples. 
	status = bladerf_enable_module(params->radioParams.dev, module, true);
	if (status != 0) {
		fprintf(stderr, "Failed to enable TX module: %s\n",
			bladerf_strerror(status));
		goto out1;
	}



	/*
	API_EXPORT
		int CALL_CONV bladerf_get_correction(struct bladerf *dev, bladerf_module module,
		bladerf_correction corr, int16_t *value);
		*/


out1:
	if (status != 0) {
		status = bladerf_enable_module(params->radioParams.dev, module, false);
		bladerf_close(params->radioParams.dev);
		stop_program = true;
		return -1;
	}

	return 0;
}


int  BladeRF_ConfigureRX(BlinkParams *params)
{
	int status;
	bladerf_module module = BLADERF_MODULE_RX;

	status = bladerf_set_frequency((params->radioParams.dev), module, params->radioParams.CentralFrequency);
	if (status != 0) {
		fprintf(stderr, "Failed to set RX frequency: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("RX Frequency: %u Hz\n", params->radioParams.CentralFrequency);
	}

	status = bladerf_set_sample_rate((params->radioParams.dev), module, params->radioParams.SampleRate, NULL);
	if (status != 0) {
		fprintf(stderr, "Failed to set RX sample rate: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("RX Samplerate: %u sps\n", params->radioParams.SampleRate);
	}

	status = bladerf_set_bandwidth((params->radioParams.dev), module,
		params->radioParams.Bandwidth, NULL);
	if (status != 0) {
		fprintf(stderr, "Failed to set RX bandwidth: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("RX Bandwidth: %u Hz\n", params->radioParams.Bandwidth);
	}


	//Receiver Specific
	status = bladerf_set_lna_gain((params->radioParams.dev), BLADE_RF_RX_LNA);
	if (status != 0) {
		fprintf(stderr, "Failed to set RX LNA gain: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("RX LNA Gain: Max\n");
	}

	status = bladerf_set_rxvga1((params->radioParams.dev), params->radioParams.RXgain);
	if (status != 0) {
		fprintf(stderr, "Failed to set RX VGA1 gain: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("RX VGA1 gain: %d\n", params->radioParams.RXgain);
	}

	status = bladerf_set_rxvga2(params->radioParams.dev, BLADE_RF_RX_VGA2);
	if (status != 0) {
		fprintf(stderr, "Failed to set RX VGA2 gain: %s\n",
			bladerf_strerror(status));
		goto out;
	}
	else {
		printf("RX VGA2 gain: %d\n\n", BLADE_RF_RX_VGA2);
	}

	// RX buffer
	params->pRxBuf = malloc(BLADE_RF_RX_BUFF_L);
	if (params->pRxBuf == NULL) {
		perror("malloc");
		exit(1);
	}

out:
	if (status != 0) {
		bladerf_close(params->radioParams.dev);
		stop_program = true;
		return -1;
	}


	// Just copied from an example
	// TBD: smart choice here?
	const unsigned int num_buffers = 16;
	const unsigned int buffer_size = 8192;  //
	const unsigned int num_transfers = 8;
	const unsigned int timeout_ms = 3500;

	// Configure both the device's RX and TX modules for use with the synchronous
	// interface. SC16 Q11 samples *without* metadata are used. 
	status = bladerf_sync_config(params->radioParams.dev,
		module,
		BLADERF_FORMAT_SC16_Q11,
		num_buffers,
		buffer_size,
		num_transfers,
		timeout_ms);

	if (status != 0) {
		fprintf(stderr, "Failed to configure RX sync interface: %s\n",
			bladerf_strerror(status));
		goto out1;
	}

	// We must always enable the modules *after* calling bladerf_sync_config(),
	// and *before* attempting to RX or TX samples. 
	status = bladerf_enable_module(params->radioParams.dev, module, true);
	if (status != 0) {
		fprintf(stderr, "Failed to enable RX module: %s\n",
			bladerf_strerror(status));
		goto out1;
	}

out1:
	if (status != 0) {
		status = bladerf_enable_module(params->radioParams.dev, module, false);
		bladerf_close(params->radioParams.dev);
		stop_program = true;
		return -1;
	}
	return 0;
}




void BladeRF_RadioStop(BlinkParams *params_tx, BlinkParams *params_rx)
{
	int rxstatus, txstatus;
	bladerf *dev;

	if (params_rx != NULL)
	{
		// Disable RX module, shutting down our underlying RX stream 
		rxstatus = bladerf_enable_module(params_rx->radioParams.dev, BLADERF_MODULE_RX, false);
		if (rxstatus != 0) {
			fprintf(stderr, "Failed to disable RX module: %s\n",
				bladerf_strerror(rxstatus));
			stop_program = true;
		}
		dev = params_rx->radioParams.dev;
	}

	if (params_tx != NULL)
	{
		txstatus = bladerf_enable_module(params_tx->radioParams.dev, BLADERF_MODULE_TX, false);
		if (txstatus != 0) {
			fprintf(stderr, "Failed to disable TX module: %s\n",
				bladerf_strerror(txstatus));
			stop_program = true;
		}
		dev = params_tx->radioParams.dev;
	}

	bladerf_close(dev);

	if (params_tx->TXBuffer != NULL)
	{
		free(params_tx->TXBuffer);
	}

	if (params_rx->pRxBuf != NULL)
	{
		free(params_rx->pRxBuf);
	}

}



// readSora reads <size> of __int16 inputs from Sora radio
// It is a blocking function and returns only once everything is read
void readBladeRF(BlinkParams *params, complex16 *ptr, int size)
{
	int status = bladerf_sync_rx(params->radioParams.dev, (int16_t*)ptr, (unsigned int)size, NULL, 5000);
	if (status != 0) {
		fprintf(stderr, "Failed to RX samples: %s\n",
			bladerf_strerror(status));
	}
}

void writeBladeRF(BlinkParams *params, complex16 *ptr, unsigned long size)
{
	/*
	for (int i = 0; i < size; ++i) {
		ptr[i].re = (((uint16_t)ptr[i].re) >> 4);
		ptr[i].im = (((uint16_t)ptr[i].im) >> 4);
	}
	*/
	
	for (int i = 0; i < size; ++i) {
		ptr[i].re += params->radioParams.DCBias;
		ptr[i].im += params->radioParams.DCBias;
	}
	
	int status = bladerf_sync_tx(params->radioParams.dev, (void*)ptr, (unsigned int)size, NULL, 5000);

	if (status != 0) {
		fprintf(stderr, "Failed to TX samples: %s\n",
			bladerf_strerror(status));

		status = bladerf_enable_module(params->radioParams.dev, BLADERF_MODULE_TX, false);
		if (status != 0) {
			fprintf(stderr, "Failed to disable TX module: %s\n",
				bladerf_strerror(status));
		}
		exit(1);
	}
}
#endif
