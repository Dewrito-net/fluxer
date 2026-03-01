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

import {useLingui} from '@lingui/react/macro';
import {observer} from 'mobx-react-lite';

export const FluxerSymbol = observer((props: React.SVGProps<SVGSVGElement>) => {
	const {t} = useLingui();

	return (
		<svg
			xmlns="http://www.w3.org/2000/svg"
			viewBox="0 0 200 200"
			role="img"
			aria-label={t`Dewrito application symbol`}
			{...props}
		>
			<g transform="translate(100,100)" fill="currentColor">
				<rect x="-24" y="-16" width="10" height="32" rx="5" opacity="0.2" />
				<rect x="-8" y="-36" width="10" height="72" rx="5" opacity="0.2" />
				<rect x="8" y="-50" width="10" height="100" rx="5" opacity="0.2" />
				<rect x="24" y="-36" width="10" height="72" rx="5" opacity="0.2" />
				<rect x="40" y="-16" width="10" height="32" rx="5" opacity="0.2" />
				<rect x="-76" y="-3" width="152" height="6" rx="3" />
				<circle cx="-78" cy="0" r="8" />
				<circle cx="78" cy="0" r="8" />
				<rect x="-34" y="-16" width="11" height="32" rx="5.5" />
				<rect x="-17" y="-36" width="11" height="72" rx="5.5" />
				<rect x="0" y="-50" width="11" height="100" rx="5.5" />
				<rect x="17" y="-36" width="11" height="72" rx="5.5" />
				<rect x="34" y="-16" width="11" height="32" rx="5.5" />
			</g>
		</svg>
	);
});
