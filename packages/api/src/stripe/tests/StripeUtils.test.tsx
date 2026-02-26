/*
 * Copyright (C) 2026 Fluxer Contributors
 *
 * This file is part of Fluxer.
 *
 * Fluxer is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * Fluxer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with Fluxer. If not, see <https://www.gnu.org/licenses/>.
 */

import {addMonthsClamp} from '@fluxer/api/src/stripe/StripeUtils';
import {describe, expect, it} from 'vitest';

// Use local-time constructor to avoid UTC midnight shifting dates across timezone boundaries.
function localDate(year: number, month: number, day: number): Date {
	return new Date(year, month - 1, day);
}

describe('addMonthsClamp', () => {
	it('adds months normally when no overflow occurs', () => {
		const result = addMonthsClamp(localDate(2024, 1, 15), 1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(15);
	});

	it('clamps Jan 31 + 1 month to Feb 29 (leap year)', () => {
		const result = addMonthsClamp(localDate(2024, 1, 31), 1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(29);
	});

	it('clamps Jan 31 + 1 month to Feb 28 (non-leap year)', () => {
		const result = addMonthsClamp(localDate(2023, 1, 31), 1);
		expect(result.getFullYear()).toBe(2023);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(28);
	});

	it('clamps Jan 30 + 1 month to Feb 28 (non-leap year)', () => {
		const result = addMonthsClamp(localDate(2023, 1, 30), 1);
		expect(result.getFullYear()).toBe(2023);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(28);
	});

	it('clamps Jan 29 + 1 month to Feb 28 (non-leap year)', () => {
		const result = addMonthsClamp(localDate(2023, 1, 29), 1);
		expect(result.getFullYear()).toBe(2023);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(28);
	});

	it('clamps Mar 31 + 1 month to Apr 30', () => {
		const result = addMonthsClamp(localDate(2024, 3, 31), 1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(3);
		expect(result.getDate()).toBe(30);
	});

	it('clamps May 31 + 1 month to Jun 30', () => {
		const result = addMonthsClamp(localDate(2024, 5, 31), 1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(5);
		expect(result.getDate()).toBe(30);
	});

	it('clamps Jul 31 + 1 month to Aug 31 (no clamping needed)', () => {
		const result = addMonthsClamp(localDate(2024, 7, 31), 1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(7);
		expect(result.getDate()).toBe(31);
	});

	it('clamps Aug 31 + 1 month to Sep 30', () => {
		const result = addMonthsClamp(localDate(2024, 8, 31), 1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(8);
		expect(result.getDate()).toBe(30);
	});

	it('clamps Oct 31 + 1 month to Nov 30', () => {
		const result = addMonthsClamp(localDate(2024, 10, 31), 1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(10);
		expect(result.getDate()).toBe(30);
	});

	it('clamps Dec 31 + 1 month to Jan 31 of next year (no clamping needed)', () => {
		const result = addMonthsClamp(localDate(2024, 12, 31), 1);
		expect(result.getFullYear()).toBe(2025);
		expect(result.getMonth()).toBe(0);
		expect(result.getDate()).toBe(31);
	});

	it('handles year boundary: Feb 29 (leap) + 12 months = Feb 28 (non-leap)', () => {
		const result = addMonthsClamp(localDate(2024, 2, 29), 12);
		expect(result.getFullYear()).toBe(2025);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(28);
	});

	it('handles multiple months: Jan 31 + 2 months = Mar 31', () => {
		const result = addMonthsClamp(localDate(2024, 1, 31), 2);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(2);
		expect(result.getDate()).toBe(31);
	});

	it('handles multiple months with clamping: Jan 31 + 3 months = Apr 30', () => {
		const result = addMonthsClamp(localDate(2024, 1, 31), 3);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(3);
		expect(result.getDate()).toBe(30);
	});

	it('handles negative months: Mar 31 - 1 month = Feb 29 (leap year)', () => {
		const result = addMonthsClamp(localDate(2024, 3, 31), -1);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(29);
	});

	it('handles negative months: Mar 31 - 1 month = Feb 28 (non-leap year)', () => {
		const result = addMonthsClamp(localDate(2023, 3, 31), -1);
		expect(result.getFullYear()).toBe(2023);
		expect(result.getMonth()).toBe(1);
		expect(result.getDate()).toBe(28);
	});

	it('handles year boundary with negative months: Jan 31 - 2 months = Nov 30', () => {
		const result = addMonthsClamp(localDate(2024, 1, 31), -2);
		expect(result.getFullYear()).toBe(2023);
		expect(result.getMonth()).toBe(10);
		expect(result.getDate()).toBe(30);
	});

	it('handles zero months (returns same date)', () => {
		const result = addMonthsClamp(localDate(2024, 1, 31), 0);
		expect(result.getFullYear()).toBe(2024);
		expect(result.getMonth()).toBe(0);
		expect(result.getDate()).toBe(31);
	});

	it('does not mutate the input date', () => {
		const input = localDate(2024, 1, 31);
		const inputTime = input.getTime();
		addMonthsClamp(input, 1);
		expect(input.getTime()).toBe(inputTime);
	});
});
